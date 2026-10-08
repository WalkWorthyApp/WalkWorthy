import { safeErrorMetadata } from '../shared/safe-logging';
import { FUNCTIONS_REVISION } from '../shared/version';
import { AccountDeletingError } from '../shared/account-lifecycle';
/**
 * Journal API
 *
 * Handles journal entry CRUD operations:
 * - POST /journal          — create a new journal entry
 * - GET /journal           — list entries (supports ?date=YYYY-MM-DD and ?limit=N)
 * - PATCH /journal/:id     — update entry text
 * - DELETE /journal/:id    — delete entry
 */

import { onRequest, HttpsOptions } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';
import type { Request, Response } from 'express';
import { getDb, COLLECTIONS, initializeFirebase } from '../shared/firebase';
import { requireAuth, verifyAppCheck, errorResponse, successResponse } from '../shared/auth';
import { checkRateLimit, sendLimitCheckResponse, STANDARD_USER_LIMIT } from '../shared/rate-limiter';
import { JournalEntry } from '../shared/types';

// Initialize Firebase on module load
initializeFirebase();

const httpsOptions: HttpsOptions = {
  maxInstances: 10,
  timeoutSeconds: 30,
  invoker: 'public',
};

const DEFAULT_LIMIT = 20;
const MAX_LIMIT = 50;
const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

/**
 * Journal API Handler
 */
export const journal = onRequest(httpsOptions, async (req, res) => {
  logger.info('journal function invoked', { revision: FUNCTIONS_REVISION });

  // App Check verification
  const appCheckValid = await verifyAppCheck(req, res);
  if (!appCheckValid) return;

  const db = getDb();

  // Authenticate and apply user rate limit
  const authReq = await requireAuth(req, res);
  if (!authReq) return;
  const { userId } = authReq;

  const userRateResult = await checkRateLimit(db, `user:${userId}:journal`, STANDARD_USER_LIMIT, userId);
  if (!userRateResult.allowed) {
    return sendLimitCheckResponse(res, 'user', userRateResult, { userId, endpoint: 'journal' });
  }

  // Determine if this is a sub-resource request (PATCH/DELETE /journal/:id)
  const pathSegment = req.path.replace(/^\/+/, '').replace(/\/+$/, '');

  switch (req.method) {
    case 'POST':
    case 'PATCH':
      return errorResponse(res, 410, 'Cloud journal writing retired; use the on-device journal');
    case 'GET':
      return handleListEntries(req, res);
    case 'DELETE':
      if (!pathSegment) {
        return errorResponse(res, 400, 'Entry ID required for DELETE');
      }
      return handleDeleteEntry(req, res, pathSegment);
    default:
      res.setHeader('Allow', 'GET, DELETE');
      return errorResponse(res, 405, `Method ${req.method} not allowed`);
  }
});

/**
 * GET /journal — List journal entries
 * Supports ?date=YYYY-MM-DD and ?limit=N
 */
async function handleListEntries(req: Request, res: Response): Promise<void> {
  const authReq = await requireAuth(req, res);
  if (!authReq) return;

  const { userId } = authReq;
  const db = getDb();

  try {
    const dateParam = req.query.date as string | undefined;
    const limitParam = req.query.limit as string | undefined;

    // Validate date param
    if (dateParam && !ISO_DATE_RE.test(dateParam)) {
      return errorResponse(res, 400, 'date must be in YYYY-MM-DD format');
    }

    // Validate and clamp limit
    let limit = DEFAULT_LIMIT;
    if (limitParam !== undefined) {
      const parsed = parseInt(limitParam, 10);
      if (isNaN(parsed) || parsed < 1) {
        return errorResponse(res, 400, 'limit must be a positive integer');
      }
      limit = Math.min(parsed, MAX_LIMIT);
    }

    let query = db
      .collection(COLLECTIONS.users)
      .doc(userId)
      .collection('journalEntries')
      .orderBy('createdAt', 'desc') as FirebaseFirestore.Query;

    if (dateParam) {
      query = query.where('date', '==', dateParam);
    }

    query = query.limit(limit);

    const snapshot = await query.get();
    const entries: JournalEntry[] = snapshot.docs.map((doc) => doc.data() as JournalEntry);

    logger.info('Journal entries listed');

    return successResponse(res, { entries });
  } catch (error) {
    if (error instanceof AccountDeletingError) return errorResponse(res, 403, 'Account deletion in progress', undefined, 'ACCOUNT_DELETING');
    logger.error('Failed to list journal entries', safeErrorMetadata(error));

    const message = 'Failed to list journal entries';
    return errorResponse(res, 500, message);
  }
}

/**
 * DELETE /journal/:id — Delete a journal entry
 */
async function handleDeleteEntry(req: Request, res: Response, entryId: string): Promise<void> {
  const authReq = await requireAuth(req, res);
  if (!authReq) return;

  const { userId } = authReq;
  const db = getDb();

  try {
    const entryRef = db
      .collection(COLLECTIONS.users)
      .doc(userId)
      .collection('journalEntries')
      .doc(entryId);

    const entryDoc = await entryRef.get();

    // 404 for both missing and wrong-owner entries (avoid leaking existence)
    if (!entryDoc.exists) {
      return errorResponse(res, 404, 'Journal entry not found');
    }

    const existing = entryDoc.data() as JournalEntry;
    if (existing.id !== entryId) {
      return errorResponse(res, 404, 'Journal entry not found');
    }

    await entryRef.delete();

    logger.info('Journal entry deleted');

    res.status(204).send();
  } catch (error) {
    if (error instanceof AccountDeletingError) return errorResponse(res, 403, 'Account deletion in progress', undefined, 'ACCOUNT_DELETING');
    logger.error('Failed to delete journal entry', safeErrorMetadata(error));

    const message = 'Failed to delete journal entry';
    return errorResponse(res, 500, message);
  }
}
