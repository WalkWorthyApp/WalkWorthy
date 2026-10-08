import { safeErrorMetadata } from '../shared/safe-logging';
import { FUNCTIONS_REVISION } from '../shared/version';
import { AccountDeletingError } from '../shared/account-lifecycle';
import { requireAiConsent, AiConsentRequiredError } from '../shared/privacy-consent';
import { createAiPersonalization } from '../shared/ai-personalization';
/**
 * Daily Reflection API
 *
 * GET /dailyReflection - Returns today's AI-generated devotional reflection.
 * Checks Firestore cache first; generates and stores on miss.
 */

import { onRequest, HttpsOptions } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import { logger } from "firebase-functions/v2";
import type { Request, Response } from "express";
import { getDb, COLLECTIONS, initializeFirebase } from "../shared/firebase";
import { requireAuth, verifyAppCheck, errorResponse, successResponse } from "../shared/auth";
import { runReflectionAgent, FIXED_REFLECTION } from "../lib/reflection-agent";
import { isCleanStoredAiContent } from "../lib/model-config";
import { collectProfileValues, sanitizeProfile } from "../lib/profile-sanitize";
import { getUserProfileOnce } from "../shared/profile";
import { getLogicalDateString, shiftLogicalDate } from "../shared/time";
import type { UserProfilePayload } from "../lib/profile-sanitize";
import type { DailyMoodSummary } from "../shared/types";
import { checkRateLimit, checkDailyAiBudget, refundDailyAiBudget, getTodayUtcDateString, sendLimitCheckResponse, DAILY_REFLECTION_USER_LIMIT, REFLECTION_DAILY_AI_BUDGET } from '../shared/rate-limiter';

initializeFirebase();

const openaiApiKey = defineSecret("openai-api-key");

const httpsOptions: HttpsOptions = {
  maxInstances: 3,
  timeoutSeconds: 60,
  invoker: "public",
  secrets: [openaiApiKey],
};

/**
 * Validates a client-supplied date string and returns it if within ±1 day of
 * the user's logical "today". Falls back to the user's logical today when the
 * client value is missing, malformed, or out of range.
 */
function resolveDate(clientDate: string | undefined, userToday: string): string {
  if (!clientDate || !/^\d{4}-\d{2}-\d{2}$/.test(clientDate)) {
    return userToday;
  }
  const userMs = new Date(`${userToday}T00:00:00Z`).getTime();
  const clientMs = new Date(`${clientDate}T00:00:00Z`).getTime();
  const oneDayMs = 24 * 60 * 60 * 1000;
  if (Math.abs(clientMs - userMs) <= oneDayMs) {
    return clientDate;
  }
  return userToday;
}

export const dailyReflection = onRequest(httpsOptions, async (req, res) => {
  logger.info("dailyReflection invoked", { revision: FUNCTIONS_REVISION });

  if (req.method !== "GET") {
    res.setHeader("Allow", "GET");
    return errorResponse(res, 405, "Method not allowed");
  }

  // App Check verification
  const appCheckValid = await verifyAppCheck(req, res);
  if (!appCheckValid) return;

  return handleGet(req, res);
});

async function handleGet(req: Request, res: Response): Promise<void> {
  const authReq = await requireAuth(req, res);
  if (!authReq) return;

  const { userId } = authReq;
  const db = getDb();

  // User-based rate limiting
  const userRateResult = await checkRateLimit(db, `user:${userId}:dailyReflection`, DAILY_REFLECTION_USER_LIMIT, userId);
  if (!userRateResult.allowed) {
    sendLimitCheckResponse(res, 'user', userRateResult, { userId, endpoint: 'dailyReflection' });
    return;
  }

  try {
    // Load profile up-front for timezone (cache key alignment) and personalization.
    const profile = await getUserProfileOnce(userId);
    const timezone = profile?.timezone || 'America/New_York';
    const userToday = getLogicalDateString(timezone);
    const today = resolveDate(req.query.date as string | undefined, userToday);

    // Check Firestore cache first
    const cacheRef = db.doc(`${COLLECTIONS.dailyReflections(userId)}/${today}`);
    const cached = await cacheRef.get();

    if (cached.exists) {
      // Re-screen before serving: cached reflections can predate the profile
      // echo-check (older ones predate any guardrail at all). A failed screen
      // drops the cache entry and falls through to regeneration below.
      const profileValues = collectProfileValues(sanitizeProfile(profile as UserProfilePayload | null));
      if (isCleanStoredAiContent(cached.data(), profileValues)) {
        logger.info("dailyReflection: cache hit");
        return successResponse(res, cached.data());
      }
      logger.warn("dailyReflection: cached reflection failed guardrail screen; regenerating");
      await cacheRef.delete();
    }

    // Window end is the anchor day; start is 6 days before (7-day inclusive window).
    // Use logical-date shifts so bucketing matches mood-checkin writes.
    const windowStart = shiftLogicalDate(today, -6);
    const summariesSnap = await db
      .collection(COLLECTIONS.moodSummaries(userId))
      .where("date", ">=", windowStart)
      .where("date", "<=", today)
      .orderBy("date", "desc")
      .limit(7)
      .get();

    const summaries: DailyMoodSummary[] = summariesSnap.docs.map(
      (d) => d.data() as DailyMoodSummary,
    );

    // Reserve an AI-budget slot BEFORE calling OpenAI. Refund on downstream
    // failure so server-side errors don't consume the user's daily quota.
    const budgetResult = await checkDailyAiBudget(db, userId, REFLECTION_DAILY_AI_BUDGET);
    if (!budgetResult.allowed) {
      sendLimitCheckResponse(res, 'dailyBudget', budgetResult, { userId, endpoint: 'dailyReflection' });
      return;
    }

    let budgetReserved = true;

    try {
      // Generate reflection
      const consent = await requireAiConsent(db, userId);
      const personalization = await createAiPersonalization(db, userId, async transaction => {
        await requireAiConsent(db, userId, transaction, consent.revision);
      });
      const result = await runReflectionAgent(summaries, openaiApiKey.value(), async () => {
        await requireAiConsent(db, userId, undefined, consent.revision);
      }, personalization);
      const generatedAt = new Date().toISOString();
      let payload = { reflection: result.reflection, isGenerated: result.isGenerated, generatedAt, date: today };

      // Cache in Firestore
      await db.runTransaction(async tx => {
        await requireAiConsent(db, userId, tx, consent.revision);
        const currentResult = result.isGenerated && !(await personalization.isResultCurrent(tx))
          ? FIXED_REFLECTION : result;
        payload = { reflection: currentResult.reflection, isGenerated: currentResult.isGenerated, generatedAt, date: today };
        tx.set(cacheRef, payload);
      });

      // Success: the slot is earned.
      budgetReserved = false;

      logger.info("dailyReflection: generated and cached");
      return successResponse(res, payload);
    } catch (aiOrWriteError) {
      // OpenAI call or Firestore write failed after budget was reserved.
      // Refund so the user isn't charged for a server-side failure. Uses
      // UTC today for the refund doc — mirrors `checkDailyAiBudget`'s UTC key.
      if (budgetReserved) {
        await refundDailyAiBudget(db, userId, getTodayUtcDateString());
      }
      throw aiOrWriteError;
    }
  } catch (error) {
    if (error instanceof AiConsentRequiredError) return errorResponse(res, 403, 'Current AI sharing consent required', undefined, 'AI_CONSENT_REQUIRED');
    if (error instanceof AccountDeletingError) return errorResponse(res, 403, 'Account deletion in progress', undefined, 'ACCOUNT_DELETING');
    logger.error("dailyReflection failed", safeErrorMetadata(error));
    const message = "Failed to generate reflection";
    return errorResponse(res, 500, message);
  }
}
