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
import { runReflectionAgent } from "../lib/reflection-agent";
import { isCleanStoredAiContent } from "../lib/model-config";
import { collectProfileValues, sanitizeProfile } from "../lib/profile-sanitize";
import { getUserProfileOnce } from "../shared/profile";
import { getLogicalDateString, shiftLogicalDate } from "../shared/time";
import type { UserProfilePayload } from "../lib/profile-sanitize";
import type { DailyMoodSummary } from "../shared/types";
import { checkRateLimit, checkDailyAiBudget, refundDailyAiBudget, getTodayUtcDateString, getClientIp, sendRateLimitResponse, DAILY_REFLECTION_USER_LIMIT, DAILY_REFLECTION_IP_LIMIT, REFLECTION_DAILY_AI_BUDGET } from '../shared/rate-limiter';

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
  logger.info("dailyReflection invoked", { method: req.method });

  if (req.method !== "GET") {
    res.setHeader("Allow", "GET");
    return errorResponse(res, 405, "Method not allowed");
  }

  // App Check verification
  const appCheckValid = await verifyAppCheck(req, res);
  if (!appCheckValid) return;

  // IP-based rate limiting
  const db = getDb();
  const clientIp = getClientIp(req);
  const ipResult = await checkRateLimit(db, `ip:${clientIp}:dailyReflection`, DAILY_REFLECTION_IP_LIMIT);
  if (!ipResult.allowed) {
    sendRateLimitResponse(res, 'ip', ipResult.retryAfterSeconds, { endpoint: 'dailyReflection' });
    return;
  }

  return handleGet(req, res);
});

async function handleGet(req: Request, res: Response): Promise<void> {
  const authReq = await requireAuth(req, res);
  if (!authReq) return;

  const { userId } = authReq;
  const db = getDb();

  // User-based rate limiting
  const userRateResult = await checkRateLimit(db, `user:${userId}:dailyReflection`, DAILY_REFLECTION_USER_LIMIT);
  if (!userRateResult.allowed) {
    sendRateLimitResponse(res, 'user', userRateResult.retryAfterSeconds, { userId, endpoint: 'dailyReflection' });
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
        logger.info("dailyReflection: cache hit", { userId, today });
        return successResponse(res, cached.data());
      }
      logger.warn("dailyReflection: cached reflection failed guardrail screen; regenerating", { userId, today });
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
      sendRateLimitResponse(res, 'dailyBudget', budgetResult.retryAfterSeconds, { userId, endpoint: 'dailyReflection' });
      return;
    }

    let budgetReserved = true;

    try {
      // Respect the opt-in toggle. Default to personalization ON when
      // optInTailored is undefined; strip profile only on explicit opt-out.
      const useProfile = profile?.optInTailored !== false;
      if (!useProfile) {
        logger.info('personalization.optedOut', { userId, endpoint: 'dailyReflection' });
      }
      const profileForAgent = useProfile ? (profile as UserProfilePayload | null) : null;

      // Generate reflection
      const reflection = await runReflectionAgent(summaries, openaiApiKey.value(), profileForAgent);
      const generatedAt = new Date().toISOString();
      const payload = { reflection, generatedAt, date: today };

      // Cache in Firestore
      await cacheRef.set(payload);

      // Success: the slot is earned.
      budgetReserved = false;

      logger.info("dailyReflection: generated and cached", { userId, today });
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
    logger.error("dailyReflection failed", {
      userId,
      error: error instanceof Error ? error.message : "unknown",
    });
    const message =
      process.env.NODE_ENV === "development"
        ? `Failed to generate reflection: ${error instanceof Error ? error.message : error}`
        : "Failed to generate reflection";
    return errorResponse(res, 500, message);
  }
}
