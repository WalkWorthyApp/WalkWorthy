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
import { requireAuth, errorResponse, successResponse } from '../shared/auth';
import { getUserProfileOnce } from '../shared/profile';
import { runMoodAgent, UserProfilePayload } from '../lib/mood-agent';
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

// Initialize Firebase on module load
initializeFirebase();

// Define the OpenAI API key secret - Firebase will inject this at runtime
const openaiApiKey = defineSecret('openai-api-key');

const httpsOptions: HttpsOptions = {
  // CORS removed - not needed for mobile-only API (mobile apps don't enforce CORS)
  maxInstances: 10,
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
 * Get the logical day date string in YYYY-MM-DD format.
 * Hours 0–2 AM still belong to the previous logical day (morning starts at 3 AM).
 */
function getLogicalDateString(timezone?: string): string {
  const now = new Date();
  let hour: number;
  try {
    if (timezone) {
      const fmt = new Intl.DateTimeFormat('en-US', {
        timeZone: timezone,
        hour: 'numeric',
        hourCycle: 'h23',
      });
      hour = parseInt(fmt.format(now), 10);
    } else {
      hour = now.getUTCHours();
    }
  } catch {
    hour = now.getUTCHours();
  }
  const logicalNow = hour < 3 ? new Date(now.getTime() - 24 * 60 * 60 * 1000) : now;
  return getDateStringInTimezone(logicalNow, timezone);
}

/**
 * Format a given date as YYYY-MM-DD in the specified timezone
 */
function getDateStringInTimezone(date: Date, timezone?: string): string {
  if (timezone) {
    try {
      const formatter = new Intl.DateTimeFormat('en-CA', {
        timeZone: timezone,
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
      });
      return formatter.format(date);
    } catch {
      // Fall back to UTC if timezone is invalid
    }
  }
  return date.toISOString().split('T')[0];
}

/**
 * Determine the current pending check-in type based on time
 */
function getCurrentCheckInType(
  timezone: string = 'America/New_York',
  checkInTimes?: { morning: string; midday: string; evening: string },
): CheckInType {
  const now = new Date();
  let hour: number;

  try {
    const formatter = new Intl.DateTimeFormat('en-US', {
      timeZone: timezone,
      hour: 'numeric',
      hourCycle: 'h23',
    });
    hour = parseInt(formatter.format(now), 10);
  } catch {
    hour = now.getUTCHours();
  }

  // Evening wraps past midnight — morning doesn't start until 3am
  const morningStart = 3;
  const morningEnd = checkInTimes ? parseInt(checkInTimes.midday.split(':')[0], 10) : 11;
  const middayEnd = checkInTimes ? parseInt(checkInTimes.evening.split(':')[0], 10) : 17;

  if (hour >= morningStart && hour < morningEnd) {
    return 'morning';
  } else if (hour >= morningEnd && hour < middayEnd) {
    return 'midday';
  } else {
    return 'evening'; // covers evening start–23 and midnight–2am
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
    // Validate input
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
        if (existingData.moodSpectrumData.moodScore === input.moodSpectrumData.moodScore &&
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

    // Step 2: Generate AI response (outside transaction - may take time)
    // NOTE: mood-agent.ts will be updated in Step 3 to accept MoodSpectrumData directly.
    // For now, bridge to the existing MoodAgentInput interface.
    const agentInput = {
      profile: profile as UserProfilePayload | null,
      checkInType: input.checkInType,
      primaryMood: input.moodSpectrumData.moodLevel,
      followUpResponse: String(input.moodSpectrumData.followUpScore),
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
          if (existingCheckInData.moodSpectrumData.moodScore === input.moodSpectrumData.moodScore &&
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
      // If concurrent duplicate detected, use the existing check-in instead
      if (txnError instanceof Error && txnError.message === 'CONCURRENT_IDENTICAL_CHECKIN') {
        // Continue - we already set finalCheckInData to the existing check-in above
      } else {
        // Re-throw any other transaction errors
        throw txnError;
      }
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

    return successResponse(res, response, 201);
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

  try {
    // Get user profile for timezone (needed for both history and current check-in)
    const profile = await getUserProfileOnce(userId);
    const timezone = profile?.timezone || 'America/New_York';

    // Check for history query
    const historyDays = req.query.history ? parseInt(req.query.history as string, 10) : undefined;
    const startDateParam = req.query.startDate as string | undefined;
    const endDateParam = req.query.endDate as string | undefined;

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
