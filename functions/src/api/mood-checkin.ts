/**
 * Mood Check-in API
 *
 * Handles mood check-in submissions and retrieval:
 * - POST /moodCheckIn - Submit a mood check-in and get AI encouragement
 * - GET /moodCheckIn - Get the latest check-in or pending check-in info
 * - GET /moodCheckIn/history - Get mood history for past days
 */

import { onRequest, HttpsOptions } from 'firebase-functions/v2/https';
import { defineSecret } from 'firebase-functions/params';
import { logger } from 'firebase-functions/v2';
import type { Request, Response } from 'express';
import { getDb, COLLECTIONS, initializeFirebase } from '../shared/firebase';
import { requireAuth, verifyAppCheck, errorResponse, successResponse } from '../shared/auth';
import { getUserProfileOnce } from '../shared/profile';
import { runMoodAgent, UserProfilePayload, MoodAgentInput } from '../lib/mood-agent';
import {
  validateCheckInType,
  validateMoodSpectrumData,
  MoodCheckIn,
  MoodCheckInInput,
  MoodCheckInResponse,
  DailyMoodSummary,
  CheckInSummary,
  CheckInType,
  MoodLevel,
  Translation,
  PendingCheckIn,
} from '../shared/types';
import { randomUUID } from 'crypto';
import {
  checkRateLimit,
  checkDailyAiBudget,
  refundDailyAiBudget,
  getTodayUtcDateString,
  getClientIp,
  sendRateLimitResponse,
  MOOD_CHECKIN_USER_LIMIT,
  MOOD_CHECKIN_IP_LIMIT,
  MOOD_DAILY_AI_BUDGET,
  STANDARD_USER_LIMIT,
  STANDARD_IP_LIMIT,
} from '../shared/rate-limiter';
import { getLogicalDateString, getDateStringInTimezone } from '../shared/time';

// Initialize Firebase on module load
initializeFirebase();

// Define the OpenAI API key secret - Firebase will inject this at runtime
const openaiApiKey = defineSecret('openai-api-key');

const httpsOptions: HttpsOptions = {
  // CORS removed - not needed for mobile-only API (mobile apps don't enforce CORS)
  maxInstances: 5,
  timeoutSeconds: 60, // AI calls may take time
  invoker: 'public',
  secrets: [openaiApiKey], // Bind OpenAI API key secret
};

const VALID_TRANSLATIONS: Translation[] = ['ESV', 'KJV', 'NIV', 'NKJV', 'NASB', 'CSB', 'NLT'];

function normalizeTranslation(value?: string): Translation {
  if (!value) return 'ESV';
  const upper = value.toUpperCase() as Translation;
  return VALID_TRANSLATIONS.includes(upper) ? upper : 'ESV';
}

/**
 * Parse an "HH:mm" string into minute-of-day. Returns undefined on any format
 * issue so callers can fall back to a default. Hours must be 0–23, minutes 0–59.
 */
function parseHHMMToMinutes(value: string): number | undefined {
  if (typeof value !== 'string') return undefined;
  const parts = value.split(':');
  if (parts.length !== 2) return undefined;
  const hh = Number(parts[0]);
  const mm = Number(parts[1]);
  if (!Number.isFinite(hh) || !Number.isFinite(mm)) return undefined;
  if (!Number.isInteger(hh) || !Number.isInteger(mm)) return undefined;
  if (hh < 0 || hh > 23 || mm < 0 || mm > 59) return undefined;
  return hh * 60 + mm;
}

// Defaults in minutes-of-day. Morning starts at 03:00 (unchanged); midday/evening
// boundaries default to the end of morning/midday respectively.
const DEFAULT_MORNING_START_MIN = 3 * 60;   // 03:00
const DEFAULT_MIDDAY_START_MIN = 11 * 60;   // 11:00 — end of morning
const DEFAULT_EVENING_START_MIN = 17 * 60;  // 17:00 — end of midday

/**
 * Determine the current pending check-in type based on time of day in the
 * user's timezone. Compares minute-of-day integers so boundaries respect the
 * minute component of the user's configured times (e.g., midday="11:59"
 * previously truncated to hour=11 and produced an empty morning window).
 */
function getCurrentCheckInType(
  timezone: string = 'America/New_York',
  checkInTimes?: { morning: string; midday: string; evening: string },
): CheckInType {
  const now = new Date();
  let nowMinutes: number;

  try {
    const formatter = new Intl.DateTimeFormat('en-US', {
      timeZone: timezone,
      hour: '2-digit',
      minute: '2-digit',
      hourCycle: 'h23',
    });
    const parts = formatter.formatToParts(now);
    const hourPart = parts.find((p) => p.type === 'hour')?.value ?? '';
    const minutePart = parts.find((p) => p.type === 'minute')?.value ?? '';
    const hh = Number(hourPart);
    const mm = Number(minutePart);
    if (!Number.isFinite(hh) || !Number.isFinite(mm)) {
      nowMinutes = now.getUTCHours() * 60 + now.getUTCMinutes();
    } else {
      nowMinutes = hh * 60 + mm;
    }
  } catch {
    nowMinutes = now.getUTCHours() * 60 + now.getUTCMinutes();
  }

  // Evening wraps past midnight — morning doesn't start until 03:00.
  const middayStart = (checkInTimes && parseHHMMToMinutes(checkInTimes.midday)) ?? DEFAULT_MIDDAY_START_MIN;
  const eveningStart = (checkInTimes && parseHHMMToMinutes(checkInTimes.evening)) ?? DEFAULT_EVENING_START_MIN;

  if (nowMinutes >= DEFAULT_MORNING_START_MIN && nowMinutes < middayStart) {
    return 'morning';
  } else if (nowMinutes >= middayStart && nowMinutes < eveningStart) {
    return 'midday';
  } else {
    return 'evening'; // covers evening start–23:59 and 00:00–02:59
  }
}

/**
 * Calculate overall sentiment from day's mood levels
 */
function calculateOverallSentiment(
  morning?: CheckInSummary | null,
  midday?: CheckInSummary | null,
  evening?: CheckInSummary | null,
): 'positive' | 'neutral' | 'challenging' | null {
  const positiveLevels: MoodLevel[] = ['pleasant', 'very_pleasant'];
  const challengingLevels: MoodLevel[] = ['unpleasant', 'very_unpleasant'];

  const levels = [morning?.moodLevel, midday?.moodLevel, evening?.moodLevel].filter(Boolean) as MoodLevel[];

  if (levels.length === 0) return null;

  let positiveCount = 0;
  let challengingCount = 0;

  for (const level of levels) {
    if (positiveLevels.includes(level)) positiveCount++;
    if (challengingLevels.includes(level)) challengingCount++;
  }

  if (positiveCount > challengingCount) return 'positive';
  if (challengingCount > positiveCount) return 'challenging';
  return 'neutral';
}

/**
 * Mood Check-in API Handler
 */
export const moodCheckIn = onRequest(httpsOptions, async (req, res) => {
  logger.info('moodCheckIn function invoked', {
    method: req.method,
    path: req.path,
    hasAuthHeader: !!req.headers.authorization,
  });

  // App Check verification
  const appCheckValid = await verifyAppCheck(req, res);
  if (!appCheckValid) return;

  // IP-based rate limiting is now split per-method inside `handlePostCheckIn`
  // and `handleGetCheckIn` so cheap GET bursts (status / history) cannot drain
  // the IP budget reserved for expensive POST traffic.

  // Route based on method
  switch (req.method) {
    case 'POST':
      return handlePostCheckIn(req, res);
    case 'GET':
      return handleGetCheckIn(req, res);
    default:
      res.setHeader('Allow', 'GET, POST');
      return errorResponse(res, 405, `Method ${req.method} not allowed`);
  }
});

/**
 * POST /moodCheckIn - Submit a mood check-in
 */
async function handlePostCheckIn(req: Request, res: Response): Promise<void> {
  const authReq = await requireAuth(req, res);
  if (!authReq) return;

  const { userId } = authReq;
  const db = getDb();

  try {
    // IP-based rate limiting for writes (separate bucket from reads so a GET
    // burst from a shared NAT can't drain the POST budget).
    const clientIp = getClientIp(req);
    const ipRateResult = await checkRateLimit(db, `ip:${clientIp}:moodCheckIn:write`, MOOD_CHECKIN_IP_LIMIT);
    if (!ipRateResult.allowed) {
      sendRateLimitResponse(res, 'ip', ipRateResult.retryAfterSeconds, { endpoint: 'moodCheckIn' });
      return;
    }

    // User-based rate limiting for writes. The `:write` suffix isolates the
    // expensive AI-call bucket from cheap status/history GETs.
    const userRateResult = await checkRateLimit(db, `user:${userId}:moodCheckIn:write`, MOOD_CHECKIN_USER_LIMIT);
    if (!userRateResult.allowed) {
      sendRateLimitResponse(res, 'user', userRateResult.retryAfterSeconds, { userId, endpoint: 'moodCheckIn' });
      return;
    }

    // Validate input before consuming daily AI budget
    const checkInType = validateCheckInType(req.body?.checkInType);
    if (!checkInType) {
      return errorResponse(res, 400, 'Invalid check-in data. Please provide a valid checkInType.');
    }
    const moodSpectrumData = validateMoodSpectrumData(req.body?.moodSpectrumData);
    if (!moodSpectrumData) {
      return errorResponse(res, 400, 'Invalid check-in data. Please provide valid moodSpectrumData.');
    }
    const input: MoodCheckInInput = { checkInType, moodSpectrumData };

    // Get user profile
    const profile = await getUserProfileOnce(userId);
    const translation = normalizeTranslation(profile?.translationPreference);
    const timezone = profile?.timezone || 'America/New_York';
    const todayDate = getLogicalDateString(timezone);

    logger.info('Processing mood check-in', {
      userId,
      checkInType: input.checkInType,
      moodLevel: input.moodSpectrumData.moodLevel,
      moodScore: input.moodSpectrumData.moodScore,
      translation,
    });

    // Use deterministic docID to prevent duplicate documents from concurrent requests
    // Format: ${todayDate}_${checkInType} ensures same document is targeted
    const checkInDocId = `${todayDate}_${input.checkInType}`;
    const checkInRef = db
      .collection(COLLECTIONS.users)
      .doc(userId)
      .collection('moodCheckIns')
      .doc(checkInDocId);

    const summaryRef = db
      .collection(COLLECTIONS.users)
      .doc(userId)
      .collection('moodSummaries')
      .doc(todayDate);

    // Step 1: Check for existing check-in inside transaction to avoid redundant AI calls under concurrency
    // Returns either: { type: 'existing', data } | { type: 'update', data } | { type: 'create' }
    const transactionResult = await db.runTransaction(async (transaction) => {
      const existingDoc = await transaction.get(checkInRef);
      if (existingDoc.exists) {
        const existingData = existingDoc.data() as MoodCheckIn;
        // If same mood score, return existing response (avoid redundant AI call)
        // Guard: old check-ins lack moodSpectrumData entirely — treat as needing update
        if (existingData.moodSpectrumData &&
            existingData.moodSpectrumData.moodScore === input.moodSpectrumData.moodScore &&
            existingData.moodSpectrumData.followUpScore === input.moodSpectrumData.followUpScore) {
          logger.info('Returning existing check-in (same mood)', {
            userId,
            checkInId: existingData.id,
            moodLevel: input.moodSpectrumData.moodLevel,
          });
          return { type: 'existing' as const, data: existingData };
        }
        // Different mood - will update after transaction
        return { type: 'update' as const, data: existingData };
      }
      // No existing - will create after transaction
      return { type: 'create' as const };
    });

    // Fast-path: Return existing response if same mood
    if (transactionResult.type === 'existing') {
      return successResponse(res, {
        checkInId: transactionResult.data.id,
        aiResponse: transactionResult.data.aiResponse,
        createdAt: transactionResult.data.createdAt,
        expiresAt: transactionResult.data.expiresAt,
        isExisting: true,
      });
    }

    // Reserve a slot in the daily AI budget BEFORE calling OpenAI. If the
    // downstream OpenAI call or Firestore write fails, we refund the slot via
    // `refundDailyAiBudget` so users aren't penalized by server-side errors.
    const budgetResult = await checkDailyAiBudget(db, userId, MOOD_DAILY_AI_BUDGET);
    if (!budgetResult.allowed) {
      sendRateLimitResponse(res, 'dailyBudget', budgetResult.retryAfterSeconds, { userId, endpoint: 'moodCheckIn' });
      return;
    }

    // The budget doc is keyed by UTC date (see `checkDailyAiBudget`), so the
    // refund must use the same UTC date — NOT the user's logical date
    // (`todayDate`) which can diverge by up to a full day near midnight for
    // users far from UTC.
    const budgetDate = getTodayUtcDateString();

    // From this point forward, any thrown error must refund the reserved slot.
    // `budgetReserved` tracks whether a refund is still owed; it flips to false
    // once the check-in has been successfully persisted.
    let budgetReserved = true;

    try {
      // Step 2: Generate AI response (outside transaction - may take time)
      // Respect the user's "Use profile for encouragements" toggle: default to
      // personalization ON when the flag is undefined (matches iOS onboarding
      // default), strip the profile only when explicitly opted out.
      const useProfile = profile?.optInTailored !== false;
      if (!useProfile) {
        logger.info('personalization.optedOut', { userId, endpoint: 'moodCheckIn' });
      }
      const agentInput: MoodAgentInput = {
        profile: useProfile ? (profile as UserProfilePayload | null) : null,
        checkInType: input.checkInType,
        moodSpectrumData: input.moodSpectrumData,
        translationPreference: translation,
      };

      const aiResponse = await runMoodAgent(agentInput, openaiApiKey.value());
      logger.info('AI response generated', { userId, verseRef: aiResponse.verseRef });

      // Step 3: Atomically write check-in and summary in final transaction
      const now = new Date();
      const expiresAt = new Date(now.getTime() + 24 * 60 * 60 * 1000);

      // Use existing check-in ID if updating, otherwise generate new one
      const checkInId = transactionResult.type === 'update' ? transactionResult.data.id : randomUUID();

      const checkInData: MoodCheckIn = {
        id: checkInId,
        checkInType: input.checkInType,
        timestamp: now.toISOString(),
        date: todayDate,
        moodSpectrumData: input.moodSpectrumData,
        aiResponse,
        createdAt: transactionResult.type === 'update' ? transactionResult.data.createdAt : now.toISOString(),
        expiresAt: expiresAt.toISOString(),
      };

      let finalCheckInData = checkInData;
      let concurrentDuplicate = false;

      try {
        await db.runTransaction(async (transaction) => {
          // Optimistic concurrency check: if a concurrent request already wrote this check-in
          // with the same mood, return that instead to avoid duplicate responses
          const existingCheckInDoc = await transaction.get(checkInRef);
          if (existingCheckInDoc.exists) {
            const existingCheckInData = existingCheckInDoc.data() as MoodCheckIn;
            if (existingCheckInData.moodSpectrumData &&
                existingCheckInData.moodSpectrumData.moodScore === input.moodSpectrumData.moodScore &&
                existingCheckInData.moodSpectrumData.followUpScore === input.moodSpectrumData.followUpScore) {
              logger.info('Concurrent request already created identical check-in, skipping write', {
                userId,
                checkInId: existingCheckInData.id,
                checkInType: input.checkInType,
              });
              finalCheckInData = existingCheckInData;
              concurrentDuplicate = true;
              // Abort transaction gracefully - we'll use the existing check-in
              throw new Error('CONCURRENT_IDENTICAL_CHECKIN');
            }
          }

          // Get existing summary within transaction
          const summaryDoc = await transaction.get(summaryRef);
          const existingSummary = summaryDoc.exists ? (summaryDoc.data() as DailyMoodSummary) : undefined;

          const checkInSummary: CheckInSummary = {
            checkInId,
            moodLevel: input.moodSpectrumData.moodLevel,
            respondedAt: now.toISOString(),
          };

          // Use null instead of undefined for Firestore compatibility
          const updatedSummary: DailyMoodSummary = {
            date: todayDate,
            morning: input.checkInType === 'morning' ? checkInSummary : (existingSummary?.morning ?? null),
            midday: input.checkInType === 'midday' ? checkInSummary : (existingSummary?.midday ?? null),
            evening: input.checkInType === 'evening' ? checkInSummary : (existingSummary?.evening ?? null),
            updatedAt: now.toISOString(),
          };

          // Calculate overall sentiment from updated check-ins
          updatedSummary.overallSentiment = calculateOverallSentiment(
            updatedSummary.morning,
            updatedSummary.midday,
            updatedSummary.evening,
          );

          // Set check-in (creates or updates - deterministic docID ensures no duplicates)
          transaction.set(checkInRef, checkInData);
          // Set summary atomically with merge to preserve any other fields
          transaction.set(summaryRef, updatedSummary, { merge: true });
        });
      } catch (txnError) {
        // If concurrent duplicate detected, use the existing check-in instead.
        // The reserved budget slot is wasted on this call but the refund path
        // below still fires because we haven't cleared `budgetReserved` yet —
        // that would let the user retry with a fresh mood. Since the
        // concurrent request already charged its own slot, we refund ours.
        if (txnError instanceof Error && txnError.message === 'CONCURRENT_IDENTICAL_CHECKIN') {
          // Continue - we already set finalCheckInData to the existing check-in above
        } else {
          // Re-throw any other transaction errors — outer catch refunds the budget slot
          throw txnError;
        }
      }

      // Write succeeded (including the concurrent-duplicate fast-path where
      // another request already persisted the check-in). In the duplicate
      // case we still refund because the concurrent request has its own
      // charge.
      if (!concurrentDuplicate) {
        budgetReserved = false;
      }

      logger.info('Mood check-in complete', {
        userId,
        checkInId: finalCheckInData.id,
        checkInType: input.checkInType,
        isUpdate: transactionResult.type === 'update',
        wasConcurrentDuplicate: concurrentDuplicate,
      });

      const response: MoodCheckInResponse = {
        checkInId: finalCheckInData.id,
        aiResponse: finalCheckInData.aiResponse,
        createdAt: finalCheckInData.createdAt,
        expiresAt: finalCheckInData.expiresAt,
      };

      // Refund the slot reserved for a concurrent duplicate before responding.
      if (budgetReserved) {
        await refundDailyAiBudget(db, userId, budgetDate);
        budgetReserved = false;
      }

      return successResponse(res, response, 201);
    } catch (aiOrWriteError) {
      // OpenAI or Firestore write failed after we reserved the budget slot.
      // Issue a compensating decrement so the failure isn't charged to the user.
      if (budgetReserved) {
        await refundDailyAiBudget(db, userId, budgetDate);
      }
      throw aiOrWriteError;
    }
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    const errorStack = error instanceof Error ? error.stack : undefined;
    const errorName = error instanceof Error ? error.name : 'Unknown';

    logger.error('Mood check-in failed', {
      userId,
      errorName,
      errorMessage,
      errorStack,
      fullError: JSON.stringify(error, Object.getOwnPropertyNames(error)),
    });

    // Only include detailed error message in non-production environments
    const message = process.env.NODE_ENV === 'development'
      ? `Failed to process check-in: ${errorMessage}`
      : 'Failed to process check-in';
    return errorResponse(res, 500, message);
  }
}

/**
 * GET /moodCheckIn - Get latest check-in or pending info
 * GET /moodCheckIn?history=7 - Get mood history for past N days
 */
async function handleGetCheckIn(req: Request, res: Response): Promise<void> {
  const authReq = await requireAuth(req, res);
  if (!authReq) return;

  const { userId } = authReq;
  const db = getDb();

  // IP-based rate limiting for reads (separate `:read` bucket so cheap status
  // and history fetches cannot drain the write budget).
  const clientIp = getClientIp(req);
  const ipRateResult = await checkRateLimit(db, `ip:${clientIp}:moodCheckIn:read`, STANDARD_IP_LIMIT);
  if (!ipRateResult.allowed) {
    sendRateLimitResponse(res, 'ip', ipRateResult.retryAfterSeconds, { endpoint: 'moodCheckIn' });
    return;
  }

  // User-based rate limiting for reads. Separate from `:write` so GETs from
  // scenePhase/onAppear handlers do not consume the AI-call budget.
  const userRateResult = await checkRateLimit(db, `user:${userId}:moodCheckIn:read`, STANDARD_USER_LIMIT);
  if (!userRateResult.allowed) {
    sendRateLimitResponse(res, 'user', userRateResult.retryAfterSeconds, { userId, endpoint: 'moodCheckIn' });
    return;
  }

  try {
    // Get user profile for timezone (needed for both history and current check-in)
    const profile = await getUserProfileOnce(userId);
    const timezone = profile?.timezone || 'America/New_York';

    // Check for history / fullHistory query (mutually exclusive modes)
    const historyDays = req.query.history ? parseInt(req.query.history as string, 10) : undefined;
    const fullHistoryDays = req.query.fullHistory ? parseInt(req.query.fullHistory as string, 10) : undefined;
    const startDateParam = req.query.startDate as string | undefined;
    const endDateParam = req.query.endDate as string | undefined;

    // Reject non-numeric history params explicitly instead of letting NaN
    // silently fall through to the "today" branch below.
    if (historyDays !== undefined && Number.isNaN(historyDays)) {
      res.status(400).json({ error: "Invalid history value. Expected a positive integer." });
      return;
    }
    if (fullHistoryDays !== undefined && Number.isNaN(fullHistoryDays)) {
      res.status(400).json({ error: "Invalid fullHistory value. Expected a positive integer." });
      return;
    }

    const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
    if (startDateParam && !ISO_DATE_RE.test(startDateParam)) {
      res.status(400).json({ error: "Invalid startDate format. Expected YYYY-MM-DD." });
      return;
    }
    if (endDateParam && !ISO_DATE_RE.test(endDateParam)) {
      res.status(400).json({ error: "Invalid endDate format. Expected YYYY-MM-DD." });
      return;
    }
    if (startDateParam && endDateParam && startDateParam > endDateParam) {
      res.status(400).json({ error: "startDate must not be after endDate." });
      return;
    }

    if (fullHistoryDays && fullHistoryDays > 0) {
      return handleGetFullHistory(userId, Math.min(fullHistoryDays, 31), db, timezone, res, startDateParam, endDateParam);
    }

    if (historyDays && historyDays > 0) {
      return handleGetHistory(userId, Math.min(historyDays, 31), db, timezone, res, startDateParam, endDateParam);
    }
    const todayDate = getLogicalDateString(timezone);

    // Get today's summary to see what check-ins are done
    const summaryRef = db
      .collection(COLLECTIONS.users)
      .doc(userId)
      .collection('moodSummaries')
      .doc(todayDate);

    const summaryDoc = await summaryRef.get();
    const summary = summaryDoc.exists ? (summaryDoc.data() as DailyMoodSummary) : undefined;

    // Determine current expected check-in type
    const currentCheckInType = getCurrentCheckInType(timezone, profile?.checkInTimes);

    // Check if current check-in is done
    const isCurrentDone =
      (currentCheckInType === 'morning' && summary?.morning) ||
      (currentCheckInType === 'midday' && summary?.midday) ||
      (currentCheckInType === 'evening' && summary?.evening);

    if (isCurrentDone) {
      // Return the latest check-in using deterministic document ID format
      const checkInDocId = `${todayDate}_${currentCheckInType}`;
      const checkInDoc = await db
        .collection(COLLECTIONS.users)
        .doc(userId)
        .collection('moodCheckIns')
        .doc(checkInDocId)
        .get();

      if (checkInDoc.exists) {
        return successResponse(res, {
          status: 'completed',
          checkIn: checkInDoc.data() as MoodCheckIn,
          summary,
        });
      } else {
        // Summary indicates completion but document not found - log inconsistency
        logger.warn('Summary indicates completed check-in but document not found', {
          userId,
          todayDate,
          checkInType: currentCheckInType,
        });
        // Fall through to return pending status
      }
    }

    // Return pending check-in info
    const now = new Date();
    const pendingCheckIn: PendingCheckIn = {
      checkInType: currentCheckInType,
      dueAt: now.toISOString(), // Could be more precise based on checkInTimes
      isOverdue: false, // Could calculate based on window
    };

    return successResponse(res, {
      status: 'pending',
      pendingCheckIn,
      summary,
    });
  } catch (error) {
    logger.error('Get check-in failed', {
      userId,
      error: error instanceof Error ? error.message : 'Unknown error',
    });

    return errorResponse(res, 500, 'Failed to retrieve check-in data.');
  }
}

/**
 * Get mood history for past N days
 */
async function handleGetHistory(userId: string, days: number, db: FirebaseFirestore.Firestore, timezone: string, res: Response, startDateOverride?: string, endDateOverride?: string): Promise<void> {
  try {
    // Compute date range in user's timezone to match stored summary keys
    const now = new Date();
    const startDate = new Date(now.getTime() - days * 24 * 60 * 60 * 1000);
    const startDateString = startDateOverride ?? getDateStringInTimezone(startDate, timezone);

    let query = db
      .collection(COLLECTIONS.users)
      .doc(userId)
      .collection('moodSummaries')
      .where('date', '>=', startDateString)
      .orderBy('date', 'desc');

    // Add upper bound when navigating to a past window
    if (endDateOverride) {
      query = query.where('date', '<=', endDateOverride);
    }

    const summariesQuery = await query
      .limit(days)
      .get();

    const summaries: DailyMoodSummary[] = summariesQuery.docs.map(
      (doc) => doc.data() as DailyMoodSummary,
    );

    logger.info('Mood history retrieved', {
      userId,
      days,
      timezone,
      startDateString,
      count: summaries.length,
    });

    return successResponse(res, {
      summaries,
      daysRequested: days,
    });
  } catch (error) {
    logger.error('Get history failed', {
      userId,
      error: error instanceof Error ? error.message : 'Unknown error',
    });

    return errorResponse(res, 500, 'Failed to retrieve mood history.');
  }
}

/**
 * Get full check-in documents (with moodSpectrumData, aiResponse, note) for
 * the past N days. Powers the Settings → Check-in log deep-dive view.
 *
 * Uses the deterministic doc-id invariant (one doc per day per check-in type,
 * max 3 per day) to cap the query size at days * 3. Within a day the iOS
 * client reorders by check-in type (morning → midday → evening).
 */
async function handleGetFullHistory(userId: string, days: number, db: FirebaseFirestore.Firestore, timezone: string, res: Response, startDateOverride?: string, endDateOverride?: string): Promise<void> {
  try {
    const now = new Date();
    const startDate = new Date(now.getTime() - days * 24 * 60 * 60 * 1000);
    const startDateString = startDateOverride ?? getDateStringInTimezone(startDate, timezone);

    let query = db
      .collection(COLLECTIONS.users)
      .doc(userId)
      .collection('moodCheckIns')
      .where('date', '>=', startDateString)
      .orderBy('date', 'desc');

    if (endDateOverride) {
      query = query.where('date', '<=', endDateOverride);
    }

    const checkInsQuery = await query
      .limit(days * 3) // morning/midday/evening per day is the upper bound
      .get();

    const checkIns: MoodCheckIn[] = checkInsQuery.docs.map(
      (doc) => doc.data() as MoodCheckIn,
    );

    logger.info('Mood full history retrieved', {
      userId,
      days,
      timezone,
      startDateString,
      count: checkIns.length,
    });

    return successResponse(res, {
      checkIns,
      daysRequested: days,
    });
  } catch (error) {
    logger.error('Get full history failed', {
      userId,
      error: error instanceof Error ? error.message : 'Unknown error',
    });

    return errorResponse(res, 500, 'Failed to retrieve check-in log.');
  }
}
