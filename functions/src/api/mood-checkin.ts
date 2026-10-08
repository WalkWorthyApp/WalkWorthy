import { FUNCTIONS_REVISION } from '../shared/version';
import { safeErrorMetadata } from '../shared/safe-logging';
import { AccountDeletingError } from '../shared/account-lifecycle';
import { requireAiConsent, AiConsentRequiredError } from '../shared/privacy-consent';
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
import { isCleanStoredAiContent } from '../lib/model-config';
import { collectProfileValues, sanitizeProfile } from '../lib/profile-sanitize';
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
  PendingCheckIn,
} from '../shared/types';
import { randomUUID } from 'crypto';
import {
  checkRateLimit,
  sendLimitCheckResponse,
  MOOD_CHECKIN_USER_LIMIT,
  STANDARD_USER_LIMIT,
} from '../shared/rate-limiter';
import { getLogicalDateString, getDateStringInTimezone } from '../shared/time';
import { sameMoodInput } from '../shared/mood-input';
import {
  claimMoodGeneration, markMoodGenerationConsumed, readMoodGenerationSettlement,
  completeMoodGeneration, failMoodGeneration, waitForMoodGeneration,
  MoodGenerationConflictError, MoodGenerationUnavailableError,
} from '../shared/mood-generation';

class CheckInConflictError extends Error {}

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
  logger.info('moodCheckIn function invoked', { revision: FUNCTIONS_REVISION });

  // App Check verification
  const appCheckValid = await verifyAppCheck(req, res);
  if (!appCheckValid) return;

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
    // User-based rate limiting for writes. The `:write` suffix isolates the
    // expensive AI-call bucket from cheap status/history GETs.
    const userRateResult = await checkRateLimit(db, `user:${userId}:moodCheckIn:write`, MOOD_CHECKIN_USER_LIMIT, userId);
    if (!userRateResult.allowed) {
      sendLimitCheckResponse(res, 'user', userRateResult, { userId, endpoint: 'moodCheckIn' });
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

    // Explicit "try again" on an already-generated check-in (App Store HIG:
    // let people retry generated content). Regeneration is NOT free — it runs
    // the agent again and so consumes the same rate limit and daily AI budget
    // as a first generation, which is what keeps it from being abusable.
    const regenerateRequested = req.body?.regenerate === true;
    const expectedCheckInId: unknown = req.body?.expectedCheckInId;

    // Get user profile
    const profile = await getUserProfileOnce(userId);
    const timezone = profile?.timezone || 'America/New_York';
    const todayDate = getLogicalDateString(timezone);

    logger.info('Processing mood check-in');

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

    // Step 1: Read the observed generation version for cache reuse/claim identity.
    // Returns either: { type: 'existing', data } | { type: 'update', data } | { type: 'create' }
    let transactionResult = await db.runTransaction(async (transaction) => {
      const existingDoc = await transaction.get(checkInRef);
      const version = existingDoc.updateTime;
      const baseVersion = version ? `${version.seconds}:${version.nanoseconds}` : 'absent';
      if (regenerateRequested && (typeof expectedCheckInId !== 'string' ||
          !existingDoc.exists || existingDoc.get('id') !== expectedCheckInId)) {
        throw new CheckInConflictError();
      }
      if (existingDoc.exists) {
        const existingData = existingDoc.data() as MoodCheckIn;
        // Reuse a response only when every submitted context field is unchanged.
        // Guard: old check-ins lack moodSpectrumData entirely — treat as needing update
        if (sameMoodInput(existingData.moodSpectrumData, input.moodSpectrumData)) {
          logger.info('Returning existing check-in (same mood)');
          return { type: 'existing' as const, data: existingData, baseVersion };
        }
        // Different mood - will update after transaction
        return { type: 'update' as const, data: existingData, baseVersion };
      }
      // No existing - will create after transaction
      return { type: 'create' as const, baseVersion };
    });

    // Fast-path: Return existing response if same mood — but only after
    // re-screening it against the CURRENT guardrails. Stored responses can
    // predate the profile echo-check, so a failed screen falls through to
    // regeneration (same flow as a mood update) instead of re-serving.
    //
    // Two things bypass the fast path, for different reasons but with the same
    // mechanics: a stored response that fails the screen, and an explicit user
    // "try again". Both must overwrite the existing doc, so both must also
    // skip the optimistic-concurrency short-circuit further down — that check
    // would otherwise re-serve the very response we were asked to replace.
    let overwriteExistingResponse = false;
    if (transactionResult.type === 'existing') {
      if (regenerateRequested) {
        logger.info('Regenerating check-in response at user request');
        overwriteExistingResponse = true;
        transactionResult = { ...transactionResult, type: 'update' as const };
      } else {
        const profileValues = collectProfileValues(sanitizeProfile(profile as UserProfilePayload | null));
        if (isCleanStoredAiContent(transactionResult.data.aiResponse, profileValues)) {
          return successResponse(res, {
            checkInId: transactionResult.data.id,
            aiResponse: transactionResult.data.aiResponse,
            createdAt: transactionResult.data.createdAt,
            expiresAt: transactionResult.data.expiresAt,
            isExisting: true,
          });
        }
        logger.warn('Stored check-in response failed guardrail screen; regenerating');
        overwriteExistingResponse = true;
        transactionResult = { ...transactionResult, type: 'update' as const };
      }
    }

    const profileValues = collectProfileValues(sanitizeProfile(profile as UserProfilePayload | null));
    let admission;
    try {
      admission = await claimMoodGeneration(db, userId, {
        checkInDocId, input: input.moodSpectrumData, regenerate: regenerateRequested,
        baseVersion: transactionResult.baseVersion,
        profileContext: profile?.optInTailored === true ? sanitizeProfile(profile as UserProfilePayload) : null,
      });
    } catch (error) {
      if (error instanceof AccountDeletingError) throw error;
      logger.error('Mood generation admission failed', safeErrorMetadata(error));
      throw new MoodGenerationUnavailableError();
    }
    if (admission.type === 'denied') {
      return sendLimitCheckResponse(res, 'dailyBudget', admission.budget, { userId, endpoint: 'moodCheckIn' });
    }
    if (admission.type === 'completed' || admission.type === 'follower') {
      const response = admission.type === 'completed' ? admission.response : await waitForMoodGeneration(admission.claim);
      if (regenerateRequested && (await checkInRef.get()).get('id') !== expectedCheckInId) throw new CheckInConflictError();
      // This is the same operation's validated result, including reviewed fixed
      // responses. An additional profile echo screen could reject harmless words
      // in a fixed crisis card that its owner successfully returned.
      return successResponse(res, response, 201);
    }
    const claim = admission.claim;

    try {
      // Step 2: Generate AI response (outside transaction - may take time)
      // Profile sharing is opt-in. Missing/legacy values remain off.
      const useProfile = profile?.optInTailored === true;
      if (!useProfile) {
        logger.info('personalization.optedOut');
      }
      const agentInput: MoodAgentInput = {
        profile: useProfile ? (profile as UserProfilePayload | null) : null,
        checkInType: input.checkInType,
        moodSpectrumData: input.moodSpectrumData,
      };

      const consent = await requireAiConsent(db, userId);
      const aiResponse = await runMoodAgent(agentInput, openaiApiKey.value(), async () => {
        await requireAiConsent(db, userId, undefined, consent.revision);
      }, undefined, undefined,
        () => markMoodGenerationConsumed(claim));
      logger.info('AI response generated');

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

      const response = await db.runTransaction(async (transaction) => {
        await requireAiConsent(db, userId, transaction, consent.revision);
        const settlement = await readMoodGenerationSettlement(transaction, claim);
        const existingCheckInDoc = await transaction.get(checkInRef);
        if (regenerateRequested && (!existingCheckInDoc.exists ||
            existingCheckInDoc.get('id') !== expectedCheckInId)) {
          throw new CheckInConflictError();
        }
        if (existingCheckInDoc.exists && !overwriteExistingResponse) {
          const existing = existingCheckInDoc.data() as MoodCheckIn;
          if (sameMoodInput(existing.moodSpectrumData, input.moodSpectrumData) &&
              isCleanStoredAiContent(existing.aiResponse, profileValues)) {
            const existingResponse: MoodCheckInResponse = {
              checkInId: existing.id, aiResponse: existing.aiResponse,
              createdAt: existing.createdAt, expiresAt: existing.expiresAt,
            };
            completeMoodGeneration(transaction, claim, settlement, existingResponse);
            return existingResponse;
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
        const savedResponse: MoodCheckInResponse = {
          checkInId: checkInData.id, aiResponse: checkInData.aiResponse,
          createdAt: checkInData.createdAt, expiresAt: checkInData.expiresAt,
        };
        completeMoodGeneration(transaction, claim, settlement, savedResponse);
        return savedResponse;
      });
      logger.info('Mood check-in complete');
      return successResponse(res, response, 201);
    } catch (aiOrWriteError) {
      // Unlike the former blanket refund, this compensates only work proven
      // unconsumed. Model/guardrail/timeouts and post-generation write failures
      // retain their daily charge, even when the user receives an error.
      try {
        await failMoodGeneration(claim, aiOrWriteError instanceof AiConsentRequiredError ? 'consent'
          : aiOrWriteError instanceof CheckInConflictError || aiOrWriteError instanceof MoodGenerationConflictError ? 'conflict' : 'failed');
      } catch (cleanupError) {
        logger.error('Mood generation cleanup failed', safeErrorMetadata(cleanupError));
      }
      throw aiOrWriteError;
    }
  } catch (error) {
    if (error instanceof MoodGenerationUnavailableError) return sendLimitCheckResponse(res, 'dailyBudget',
      { allowed: false, retryAfterSeconds: 60, failure: 'unavailable' }, { userId, endpoint: 'moodCheckIn' });
    if (error instanceof CheckInConflictError || error instanceof MoodGenerationConflictError) return errorResponse(res, 409, 'This check-in has changed. Close and reopen it before trying again.');
    if (error instanceof AiConsentRequiredError) return errorResponse(res, 403, 'Current AI sharing consent required', undefined, 'AI_CONSENT_REQUIRED');
    if (error instanceof AccountDeletingError) return errorResponse(res, 403, 'Account deletion in progress', undefined, 'ACCOUNT_DELETING');

    logger.error('Mood check-in failed', safeErrorMetadata(error));

    // Only include detailed error message in non-production environments
    const message = 'Failed to process check-in';
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

  // User-based rate limiting for reads. Separate from `:write` so GETs from
  // scenePhase/onAppear handlers do not consume the AI-call budget.
  const userRateResult = await checkRateLimit(db, `user:${userId}:moodCheckIn:read`, STANDARD_USER_LIMIT, userId);
  if (!userRateResult.allowed) {
    sendLimitCheckResponse(res, 'user', userRateResult, { userId, endpoint: 'moodCheckIn' });
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

    // Screen values for re-serving stored AI responses (see isCleanStoredAiContent).
    const profileValues = collectProfileValues(sanitizeProfile(profile as UserProfilePayload | null));

    if (fullHistoryDays && fullHistoryDays > 0) {
      return handleGetFullHistory(userId, Math.min(fullHistoryDays, 31), db, timezone, res, profileValues, startDateParam, endDateParam);
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
        const storedCheckIn = checkInDoc.data() as MoodCheckIn;
        // Re-screen the stored response before serving (it may predate the
        // current guardrails). On failure, fall through to pending — the
        // re-submitted check-in then regenerates via the POST screen path.
        if (isCleanStoredAiContent(storedCheckIn.aiResponse, profileValues)) {
          return successResponse(res, {
            status: 'completed',
            checkIn: storedCheckIn,
            summary,
          });
        }
        logger.warn('Stored check-in response failed guardrail screen on read; returning pending');
        // Fall through to return pending status
      } else {
        // Summary indicates completion but document not found - log inconsistency
        logger.warn('Summary indicates completed check-in but document not found');
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
    // No AiConsentRequiredError branch: reads never call requireAiConsent.
    // Mood history is the user's own stored data and must stay readable after
    // AI sharing is withdrawn.
    if (error instanceof AccountDeletingError) return errorResponse(res, 403, 'Account deletion in progress', undefined, 'ACCOUNT_DELETING');
    logger.error('Get check-in failed');

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

    logger.info('Mood history retrieved');

    return successResponse(res, {
      summaries,
      daysRequested: days,
    });
  } catch (error) {
    if (error instanceof AccountDeletingError) return errorResponse(res, 403, 'Account deletion in progress', undefined, 'ACCOUNT_DELETING');
    logger.error('Get history failed');

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
async function handleGetFullHistory(userId: string, days: number, db: FirebaseFirestore.Firestore, timezone: string, res: Response, profileValues: readonly string[], startDateOverride?: string, endDateOverride?: string): Promise<void> {
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

    const allCheckIns: MoodCheckIn[] = checkInsQuery.docs.map(
      (doc) => doc.data() as MoodCheckIn,
    );

    // Re-screen stored responses before serving (they may predate the
    // current guardrails); entries failing the screen are omitted from the
    // log rather than served with unscreened content.
    const checkIns = allCheckIns.filter(
      (c) => isCleanStoredAiContent(c.aiResponse, profileValues),
    );
    if (checkIns.length < allCheckIns.length) {
      logger.warn('Omitted stored check-ins that failed guardrail screen');
    }

    logger.info('Mood full history retrieved');

    return successResponse(res, {
      checkIns,
      daysRequested: days,
    });
  } catch (error) {
    if (error instanceof AccountDeletingError) return errorResponse(res, 403, 'Account deletion in progress', undefined, 'ACCOUNT_DELETING');
    logger.error('Get full history failed');

    return errorResponse(res, 500, 'Failed to retrieve check-in log.');
  }
}
