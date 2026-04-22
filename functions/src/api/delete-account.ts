/**
 * Delete Account API
 *
 * Apple App Store Guideline 5.1.1(v) compliance: any app offering in-app
 * account creation must provide an in-app account deletion mechanism.
 *
 * POST /deleteAccount
 *  - Requires a valid Firebase ID token (and App Check).
 *  - Derives userId ONLY from the verified token — never from the body —
 *    to prevent account-deletion IDOR.
 *  - Deletes every Firestore document owned by the user, then the Auth user.
 *  - Idempotent: a second call finds nothing to delete; `auth/user-not-found`
 *    is treated as success.
 *
 * Deletion order (strict — do not reorder without updating error handling):
 *   1. Every subcollection under users/{userId} (enumerated at runtime).
 *   2. `_rateLimits` docs whose ID is prefixed with `user:<userId>:`.
 *   3. `_dailyBudgets` docs whose ID is prefixed with `<userId>_`.
 *   4. The parent `users/{userId}` document itself.
 *   5. Firebase Auth user via admin.auth().deleteUser().
 *
 * If steps 1-4 fail mid-way we do NOT delete the Auth user — a partially-
 * deleted account is worse than a full retry, since the caller can safely
 * call this endpoint again.
 */

import { onRequest, HttpsOptions } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';
import { FieldPath } from 'firebase-admin/firestore';
import type { Firestore, CollectionReference, BulkWriter } from 'firebase-admin/firestore';
import { getDb, getAuthInstance, initializeFirebase } from '../shared/firebase';
import { requireAuth, verifyAppCheck, errorResponse, successResponse } from '../shared/auth';
import { checkRateLimit, getClientIp, sendRateLimitResponse } from '../shared/rate-limiter';
import type { RateLimitConfig } from '../shared/rate-limiter';

// Initialize Firebase on module load
initializeFirebase();

const httpsOptions: HttpsOptions = {
  maxInstances: 10,
  // Bulk recursive deletion across many subcollections can take several seconds.
  // 60s is conservative; an active user rarely exceeds a few hundred docs total.
  timeoutSeconds: 60,
  invoker: 'public',
};

/**
 * Deliberately strict: 3 successful deletions per hour per user is far
 * above any legitimate use case (a user should delete their account once).
 * Keeps the endpoint from being weaponized by a stolen token to hammer
 * Firestore.
 */
const DELETE_ACCOUNT_USER_LIMIT: RateLimitConfig = { maxRequests: 3, windowMs: 3600000 };
const DELETE_ACCOUNT_IP_LIMIT: RateLimitConfig = { maxRequests: 10, windowMs: 3600000 };

/**
 * Firestore doesn't support prefix `startsWith` queries directly, so we
 * emulate one with a documentId() range: [prefix, prefix + '\uf8ff'). The
 * high sentinel is the highest valid UTF-8 code point, which Firestore
 * guarantees sorts after any document ID beginning with `prefix`.
 */
const PREFIX_HIGH_SENTINEL = '\uf8ff';

export const deleteAccount = onRequest(httpsOptions, async (req, res) => {
  // Only POST is semantically correct for a destructive, non-idempotent-from-
  // the-server's-perspective action. (Idempotent from the client's POV, but
  // POST is the right HTTP verb — DELETE would also be defensible but POST
  // aligns with the rest of this codebase's write endpoints.)
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return errorResponse(res, 405, `Method ${req.method} not allowed`);
  }

  // App Check first — cheapest rejection for abuse.
  const appCheckValid = await verifyAppCheck(req, res);
  if (!appCheckValid) return;

  const db = getDb();

  // IP-based rate limit.
  const clientIp = getClientIp(req);
  const ipResult = await checkRateLimit(db, `ip:${clientIp}:deleteAccount`, DELETE_ACCOUNT_IP_LIMIT);
  if (!ipResult.allowed) {
    sendRateLimitResponse(res, 'ip', ipResult.retryAfterSeconds, { endpoint: 'deleteAccount' });
    return;
  }

  // Authenticate — userId comes ONLY from the verified token.
  const authReq = await requireAuth(req, res);
  if (!authReq) return;
  const { userId } = authReq;

  // User-based rate limit.
  const userRateResult = await checkRateLimit(
    db,
    `user:${userId}:deleteAccount`,
    DELETE_ACCOUNT_USER_LIMIT
  );
  if (!userRateResult.allowed) {
    sendRateLimitResponse(res, 'user', userRateResult.retryAfterSeconds, {
      userId,
      endpoint: 'deleteAccount',
    });
    return;
  }

  logger.info('Account deletion requested', { userId, endpoint: 'deleteAccount', action: 'start' });

  // ---------------------------------------------------------------------------
  // Phase 1: Firestore cleanup. If anything here throws, we return 500 and the
  // Auth user is LEFT INTACT so the client can retry safely.
  // ---------------------------------------------------------------------------
  try {
    await deleteAllUserFirestoreData(db, userId);
  } catch (err) {
    logger.error('Account deletion: Firestore cleanup failed', {
      userId,
      endpoint: 'deleteAccount',
      phase: 'firestore',
      error: err instanceof Error ? err.message : String(err),
    });
    return errorResponse(res, 500, 'Account deletion failed; please retry');
  }

  // ---------------------------------------------------------------------------
  // Phase 2: Firebase Auth user deletion. If this fails after Firestore data
  // has been wiped we surface a distinct error code so support can finish the
  // cleanup manually — the user's data is already gone at this point.
  // ---------------------------------------------------------------------------
  try {
    await getAuthInstance().deleteUser(userId);
  } catch (err) {
    // Idempotency: if the auth user is already gone (e.g. a retry after a
    // previous successful run), treat it as success.
    if (isAuthUserNotFound(err)) {
      logger.info('Account deletion: Auth user already absent (idempotent success)', {
        userId,
        endpoint: 'deleteAccount',
        action: 'complete',
      });
      return successResponse(res, { deleted: true });
    }

    logger.error('Account deletion: Auth user delete failed after Firestore wipe', {
      userId,
      endpoint: 'deleteAccount',
      phase: 'auth',
      code: 'AUTH_DELETE_FAILED',
      error: err instanceof Error ? err.message : String(err),
    });
    return errorResponse(
      res,
      500,
      'Account data removed, but auth record could not be deleted. Contact support.',
      { code: 'AUTH_DELETE_FAILED' }
    );
  }

  logger.info('Account deletion complete', {
    userId,
    endpoint: 'deleteAccount',
    action: 'complete',
  });
  return successResponse(res, { deleted: true });
});

// ============================================================================
// Helpers
// ============================================================================

/**
 * Orchestrates the Firestore portion of account deletion. Throws on any
 * unrecoverable error — callers must treat that as "do not delete the Auth
 * user yet".
 */
async function deleteAllUserFirestoreData(db: Firestore, userId: string): Promise<void> {
  const userDocRef = db.collection('users').doc(userId);
  const writer = db.bulkWriter();

  // BulkWriter default retry behavior handles transient errors automatically.
  // We surface only truly terminal failures so the top-level catch can log them.
  let terminalError: Error | null = null;
  writer.onWriteError((err) => {
    // Keep retrying up to 5 attempts (BulkWriter default is 10 but 5 is plenty
    // for Firestore's backoff curve). Returning true retries; false surrenders.
    if (err.failedAttempts < 5) {
      return true;
    }
    terminalError = err;
    return false;
  });

  // 1. Every subcollection under users/{userId} — enumerate dynamically so
  //    future collections (added by other engineers) are cleaned up too.
  const subcollections = await userDocRef.listCollections();
  for (const sub of subcollections) {
    await queueCollectionDeletes(writer, sub);
  }

  // 2. Rate-limit docs owned by this user: IDs look like `user:<userId>:<endpoint>`.
  await queuePrefixMatchDeletes(writer, db.collection('_rateLimits'), `user:${userId}:`);

  // 3. Daily-budget docs: IDs look like `<userId>_<YYYY-MM-DD>`.
  await queuePrefixMatchDeletes(writer, db.collection('_dailyBudgets'), `${userId}_`);

  // 4. Parent users/{userId} document itself.
  writer.delete(userDocRef);

  // Flush everything. If a terminal error was recorded, throw it so the
  // caller aborts before deleting the Auth user.
  await writer.close();
  if (terminalError) {
    throw terminalError;
  }
}

/**
 * Queues every document in a collection for deletion via the BulkWriter.
 * Paginates with a page size of 500 to bound memory on large collections.
 *
 * Note: we intentionally do NOT descend into nested subcollections here.
 * None of WalkWorthy's user-scoped collections contain nested subcollections
 * today, and `listCollections()` on the parent user doc already enumerates
 * the top-level set. If that changes, switch to `db.recursiveDelete(ref)` —
 * but that helper blocks on its own BulkWriter, so batching becomes trickier.
 */
async function queueCollectionDeletes(
  writer: BulkWriter,
  collection: CollectionReference
): Promise<void> {
  const PAGE_SIZE = 500;
  while (true) {
    const snap = await collection.limit(PAGE_SIZE).get();
    if (snap.empty) return;
    for (const doc of snap.docs) {
      writer.delete(doc.ref);
    }
    // Flush the current page so the `limit(PAGE_SIZE).get()` on the next
    // iteration doesn't keep returning the same docs (they may not be
    // removed yet if we haven't flushed). Also caps in-flight ops.
    await writer.flush();
    if (snap.size < PAGE_SIZE) return;
  }
}

/**
 * Queues every document whose ID starts with `prefix` for deletion.
 * Implemented as a documentId() range query, which is the idiomatic way
 * to emulate startsWith in Firestore.
 */
async function queuePrefixMatchDeletes(
  writer: BulkWriter,
  collection: CollectionReference,
  prefix: string
): Promise<void> {
  const PAGE_SIZE = 500;
  // Fetch once; prefix matches for _rateLimits / _dailyBudgets per user are
  // bounded by endpoint count + retention window (tens of docs at most).
  const snap = await collection
    .where(FieldPath.documentId(), '>=', prefix)
    .where(FieldPath.documentId(), '<', prefix + PREFIX_HIGH_SENTINEL)
    .limit(PAGE_SIZE)
    .get();

  if (snap.empty) return;
  for (const doc of snap.docs) {
    writer.delete(doc.ref);
  }
  // If we ever hit the page cap (unlikely), log so we notice and upgrade to
  // a paginated loop like queueCollectionDeletes.
  if (snap.size >= PAGE_SIZE) {
    logger.warn('Prefix-match delete hit page cap; some docs may remain', {
      collection: collection.id,
      prefix,
      pageSize: PAGE_SIZE,
    });
  }
}

/**
 * Narrows an unknown error to the Firebase Auth "user not found" case.
 * The Admin SDK throws with `code === 'auth/user-not-found'`.
 */
function isAuthUserNotFound(err: unknown): boolean {
  if (!err || typeof err !== 'object') return false;
  const code = (err as { code?: unknown }).code;
  return code === 'auth/user-not-found';
}

