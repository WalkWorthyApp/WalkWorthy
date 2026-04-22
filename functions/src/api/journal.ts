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
import { checkRateLimit, getClientIp, STANDARD_USER_LIMIT, STANDARD_IP_LIMIT } from '../shared/rate-limiter';
import { getUserLogicalDate } from '../shared/time';
import { JournalEntry } from '../shared/types';
import { randomUUID } from 'crypto';

// Initialize Firebase on module load
initializeFirebase();

const httpsOptions: HttpsOptions = {
  maxInstances: 10,
  timeoutSeconds: 30,
  invoker: 'public',
};

const MAX_TEXT_LENGTH = 2000;
const DEFAULT_LIMIT = 20;
const MAX_LIMIT = 50;
const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

/**
 * Journal API Handler
 */
export const journal = onRequest(httpsOptions, async (req, res) => {
  logger.info('journal function invoked', {
    method: req.method,
    path: req.path,
    hasAuthHeader: !!req.headers.authorization,
  });

  // App Check verification
  const appCheckValid = await verifyAppCheck(req, res);
  if (!appCheckValid) return;

  // IP-based rate limiting
  const db = getDb();
  const clientIp = getClientIp(req);
  const ipResult = await checkRateLimit(db, `ip:${clientIp}:journal`, STANDARD_IP_LIMIT);
  if (!ipResult.allowed) {
    res.set('Retry-After', String(ipResult.retryAfterSeconds));
    return errorResponse(res, 429, 'Too many requests. Please try again later.');
  }

  // Authenticate and apply user rate limit
  const authReq = await requireAuth(req, res);
  if (!authReq) return;
  const { userId } = authReq;

  const userRateResult = await checkRateLimit(db, `user:${userId}:journal`, STANDARD_USER_LIMIT);
  if (!userRateResult.allowed) {
    res.set('Retry-After', String(userRateResult.retryAfterSeconds));
    return errorResponse(res, 429, 'Too many requests. Please try again later.');
  }

  // Determine if this is a sub-resource request (PATCH/DELETE /journal/:id)
  const pathSegment = req.path.replace(/^\/+/, '').replace(/\/+$/, '');

  switch (req.method) {
    case 'POST':
      return handleCreateEntry(req, res);
    case 'GET':
      return handleListEntries(req, res);
    case 'PATCH':
      if (!pathSegment) {
        return errorResponse(res, 400, 'Entry ID required for PATCH');
      }
      return handleUpdateEntry(req, res, pathSegment);
    case 'DELETE':
      if (!pathSegment) {
        return errorResponse(res, 400, 'Entry ID required for DELETE');
      }
      return handleDeleteEntry(req, res, pathSegment);
    default:
      res.setHeader('Allow', 'GET, POST, PATCH, DELETE');
      return errorResponse(res, 405, `Method ${req.method} not allowed`);
  }
});

/**
 * POST /journal — Create a new journal entry
 */
async function handleCreateEntry(req: Request, res: Response): Promise<void> {
  const authReq = await requireAuth(req, res);
  if (!authReq) return;

  const { userId } = authReq;
  const db = getDb();

  try {
    // Validate text
    const { text, linkedCheckInId } = req.body ?? {};

    if (typeof text !== 'string' || text.trim().length === 0) {
      return errorResponse(res, 400, 'text is required and must be a non-empty string');
    }
    if (text.length > MAX_TEXT_LENGTH) {
      return errorResponse(res, 400, `text must not exceed ${MAX_TEXT_LENGTH} characters`);
    }
    if (linkedCheckInId !== undefined && typeof linkedCheckInId !== 'string') {
      return errorResponse(res, 400, 'linkedCheckInId must be a string if provided');
    }

    const now = new Date();
    // Bucket entries by the user's logical date so journal entries align with
    // mood check-in summaries (which also use logical dates in the user's
    // timezone). UTC bucketing would misalign by several hours for users far
    // from UTC and put late-night entries on the "wrong" day.
    const date = await getUserLogicalDate(userId);
    const entryId = randomUUID();
    const nowIso = now.toISOString();

    const entry: JournalEntry = {
      id: entryId,
      text: text.trim(),
      date,
      createdAt: nowIso,
      updatedAt: nowIso,
      ...(typeof linkedCheckInId === 'string' ? { linkedCheckInId } : {}),
    };

    await db
      .collection(COLLECTIONS.users)
      .doc(userId)
      .collection('journalEntries')
      .doc(entryId)
      .set(entry);

    logger.info('Journal entry created', { userId, entryId });

    return successResponse(res, entry, 201);
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    logger.error('Failed to create journal entry', { userId, errorMessage });

    const message = process.env.NODE_ENV === 'development'
      ? `Failed to create journal entry: ${errorMessage}`
      : 'Failed to create journal entry';
    return errorResponse(res, 500, message);
  }
}

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

    logger.info('Journal entries listed', { userId, count: entries.length });

    return successResponse(res, { entries });
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    logger.error('Failed to list journal entries', { userId, errorMessage });

    const message = process.env.NODE_ENV === 'development'
      ? `Failed to list journal entries: ${errorMessage}`
      : 'Failed to list journal entries';
    return errorResponse(res, 500, message);
  }
}

/**
 * PATCH /journal/:id — Update entry text
 */
async function handleUpdateEntry(req: Request, res: Response, entryId: string): Promise<void> {
  const authReq = await requireAuth(req, res);
  if (!authReq) return;

  const { userId } = authReq;
  const db = getDb();

  try {
    // Validate text
    const { text } = req.body ?? {};

    if (typeof text !== 'string' || text.trim().length === 0) {
      return errorResponse(res, 400, 'text is required and must be a non-empty string');
    }
    if (text.length > MAX_TEXT_LENGTH) {
      return errorResponse(res, 400, `text must not exceed ${MAX_TEXT_LENGTH} characters`);
    }

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

    // Ownership check — entry's implicit owner is the userId in the path, but verify
    // against the stored id to ensure the document belongs to this user's sub-collection
    if (existing.id !== entryId) {
      return errorResponse(res, 404, 'Journal entry not found');
    }

    const nowIso = new Date().toISOString();
    const updated: JournalEntry = {
      ...existing,
      text: text.trim(),
      updatedAt: nowIso,
    };

    await entryRef.set(updated);

    logger.info('Journal entry updated', { userId, entryId });

    return successResponse(res, updated);
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    logger.error('Failed to update journal entry', { userId, entryId, errorMessage });

    const message = process.env.NODE_ENV === 'development'
      ? `Failed to update journal entry: ${errorMessage}`
      : 'Failed to update journal entry';
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

    logger.info('Journal entry deleted', { userId, entryId });

    res.status(204).send();
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    logger.error('Failed to delete journal entry', { userId, entryId, errorMessage });

    const message = process.env.NODE_ENV === 'development'
      ? `Failed to delete journal entry: ${errorMessage}`
      : 'Failed to delete journal entry';
    return errorResponse(res, 500, message);
  }
}
