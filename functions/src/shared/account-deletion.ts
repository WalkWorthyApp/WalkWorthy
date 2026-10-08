import { randomUUID } from 'node:crypto';
import { FieldPath, FieldValue, Timestamp } from 'firebase-admin/firestore';
import type { Firestore } from 'firebase-admin/firestore';
import { deletionRef } from './account-lifecycle';

const CLIENT_WINDOW_MS = 60 * 60 * 1000;
const CLIENT_ATTEMPT_LIMIT = 3;
// Longer than the HTTP/worker timeout, preventing simultaneous cleanup.
const LEASE_MS = 10 * 60 * 1000;
const RETRY_MS = 15 * 60 * 1000;
const COMPLETED_TTL_MS = 7 * 24 * 60 * 60 * 1000;

export interface DeletionAuth {
  verifyIdToken(token: string, checkRevoked?: boolean): Promise<{ uid: string }>;
  deleteUser(uid: string): Promise<void>;
}

export type DeletionResult =
  | { status: 'completed' }
  | { status: 'busy' }
  | { status: 'rate-limited'; retryAfterSeconds: number };

/** Only emitted after a durable deletion job has been confirmed. Keep the
 * original failure even when releasing the worker lease also fails. */
export class PendingDeletionError extends Error {
  constructor(readonly cause: unknown, readonly releaseError?: unknown) {
    super('Account deletion is pending automatic retry');
    this.name = 'PendingDeletionError';
  }
}

export async function deleteAllUserFirestoreData(db: Firestore, uid: string): Promise<void> {
  await db.recursiveDelete(db.collection('users').doc(uid));
  for (const [collection, prefix] of [['_rateLimits', `user:${uid}:`], ['_dailyBudgets', `${uid}_`]]) {
    for (;;) {
      const page = await db.collection(collection).where(FieldPath.documentId(), '>=', prefix)
        .where(FieldPath.documentId(), '<', prefix + '\uf8ff').limit(400).get();
      if (page.empty) break;
      const batch = db.batch();
      page.docs.forEach(doc => batch.delete(doc.ref));
      await batch.commit();
    }
  }
}

/** All callers share one lease. Attempts live in the barrier, never in a
 * separate quota record that a concurrent retry could recreate after erasure. */
export async function resumeAccountDeletion(
  db: Firestore,
  auth: Pick<DeletionAuth, 'deleteUser'>,
  uid: string,
  source: 'client' | 'worker',
  cleanup = deleteAllUserFirestoreData,
): Promise<DeletionResult> {
  const marker = deletionRef(db, uid);
  const leaseId = randomUUID();
  const claim = await db.runTransaction(async tx => {
    const current = await tx.get(marker);
    const data = current.data();
    if (data?.status === 'completed') return { status: 'completed' } as const;
    // Workers may only resume an authenticated request, never create one.
    if (data?.status !== 'deleting' && source === 'worker') return { status: 'busy' } as const;
    const now = Date.now();
    if (data?.leaseUntil instanceof Timestamp && data.leaseUntil.toMillis() > now) {
      return { status: 'busy' } as const;
    }
    const attempts: number[] = Array.isArray(data?.clientAttempts)
      ? data.clientAttempts.filter((value: unknown): value is number =>
        typeof value === 'number' && value > now - CLIENT_WINDOW_MS)
      : [];
    if (source === 'client' && attempts.length >= CLIENT_ATTEMPT_LIMIT) {
      return { status: 'rate-limited',
        retryAfterSeconds: Math.ceil((Math.min(...attempts) + CLIENT_WINDOW_MS - now) / 1000) } as const;
    }
    if (source === 'client') attempts.push(now);
    const leaseUntil = Timestamp.fromMillis(now + LEASE_MS);
    // Replace to remove any legacy expiresAt. Only completed markers have TTL.
    tx.set(marker, { status: 'deleting', startedAt: data?.startedAt ?? Timestamp.now(),
      clientAttempts: attempts, leaseId, leaseUntil, nextAttemptAt: leaseUntil });
    return { status: 'claimed' } as const;
  });
  if (claim.status !== 'claimed') return claim;

  try {
    await cleanup(db, uid);
    try {
      await auth.deleteUser(uid);
    } catch (error) {
      if (!error || typeof error !== 'object' || (error as { code?: unknown }).code !== 'auth/user-not-found') throw error;
    }
    await db.runTransaction(async tx => {
      const current = await tx.get(marker);
      if (current.data()?.leaseId !== leaseId) return;
      tx.set(marker, { status: 'completed',
        expiresAt: Timestamp.fromMillis(Date.now() + COMPLETED_TTL_MS) });
    });
    return { status: 'completed' };
  } catch (error) {
    // A failed release is safe: the lease expires and the worker tries again.
    try {
      await db.runTransaction(async tx => {
        const current = await tx.get(marker);
        if (current.data()?.leaseId !== leaseId) return;
        tx.update(marker, { leaseId: FieldValue.delete(), leaseUntil: FieldValue.delete(),
          nextAttemptAt: Timestamp.fromMillis(Date.now() + RETRY_MS) });
      });
    } catch (releaseError) {
      throw new PendingDeletionError(error, releaseError);
    }
    throw new PendingDeletionError(error);
  }
}

/** Verify revocation before the first persistent write. A signed, unexpired
 * token can resume its existing deletion even after the Auth user was erased. */
export async function requestAccountDeletion(
  db: Firestore, auth: DeletionAuth, token: string,
): Promise<DeletionResult> {
  const decoded = await auth.verifyIdToken(token);
  const existing = await deletionRef(db, decoded.uid).get();
  if (existing.data()?.status === 'completed') return { status: 'completed' };
  const alreadyPending = existing.data()?.status === 'deleting';
  if (!alreadyPending) await auth.verifyIdToken(token, true);
  try {
    return await resumeAccountDeletion(db, auth, decoded.uid, 'client');
  } catch (error) {
    // A failed claim is still resumable when this request read a saved job.
    // Otherwise its commit outcome is unknown: do not promise automatic retry.
    if (alreadyPending && !(error instanceof PendingDeletionError)) {
      throw new PendingDeletionError(error);
    }
    throw error;
  }
}

/** Bounded recovery, oldest due requests first; uses a single-field index. */
export async function retryPendingAccountDeletions(
  db: Firestore, auth: Pick<DeletionAuth, 'deleteUser'>,
): Promise<{ completed: number; failed: number; busy: number }> {
  const due = await db.collection('_accountDeletions').orderBy('nextAttemptAt')
    .endAt(Timestamp.now()).limit(10).get();
  const results = await Promise.allSettled(due.docs.map(doc =>
    resumeAccountDeletion(db, auth, doc.id, 'worker')));
  return results.reduce((counts, result) => {
    if (result.status === 'rejected') counts.failed += 1;
    else if (result.value.status === 'completed') counts.completed += 1;
    else counts.busy += 1;
    return counts;
  }, { completed: 0, failed: 0, busy: 0 });
}
