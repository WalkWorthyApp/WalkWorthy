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
import type { DailyMoodSummary } from "../shared/types";
import { checkRateLimit, checkDailyAiBudget, getClientIp, sendRateLimitResponse, DAILY_REFLECTION_USER_LIMIT, DAILY_REFLECTION_IP_LIMIT, REFLECTION_DAILY_AI_BUDGET } from '../shared/rate-limiter';

initializeFirebase();

const openaiApiKey = defineSecret("openai-api-key");

const httpsOptions: HttpsOptions = {
  maxInstances: 3,
  timeoutSeconds: 60,
  invoker: "public",
  secrets: [openaiApiKey],
};

function getServerUTCDateString(): string {
  return new Date().toISOString().split("T")[0];
}

/** Validates a client-supplied date string and returns it if within ±1 day of server UTC. */
function resolveDate(clientDate: string | undefined): string {
  const serverToday = getServerUTCDateString();
  if (!clientDate || !/^\d{4}-\d{2}-\d{2}$/.test(clientDate)) {
    return serverToday;
  }
  const serverMs = new Date(serverToday).getTime();
  const clientMs = new Date(clientDate).getTime();
  const oneDayMs = 24 * 60 * 60 * 1000;
  if (Math.abs(clientMs - serverMs) <= oneDayMs) {
    return clientDate;
  }
  return serverToday;
}

function getSevenDaysAgoString(today: string): string {
  const d = new Date(today);
  d.setDate(d.getDate() - 6);
  return d.toISOString().split("T")[0];
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
  const today = resolveDate(req.query.date as string | undefined);

  // User-based rate limiting
  const userRateResult = await checkRateLimit(db, `user:${userId}:dailyReflection`, DAILY_REFLECTION_USER_LIMIT);
  if (!userRateResult.allowed) {
    sendRateLimitResponse(res, 'user', userRateResult.retryAfterSeconds, { userId, endpoint: 'dailyReflection' });
    return;
  }

  try {
    // Check Firestore cache first
    const cacheRef = db.doc(`${COLLECTIONS.dailyReflections(userId)}/${today}`);
    const cached = await cacheRef.get();

    if (cached.exists) {
      logger.info("dailyReflection: cache hit", { userId, today });
      return successResponse(res, cached.data());
    }

    // Fetch past 7 days of mood summaries
    const summariesSnap = await db
      .collection(COLLECTIONS.moodSummaries(userId))
      .where("date", ">=", getSevenDaysAgoString(today))
      .where("date", "<=", today)
      .orderBy("date", "desc")
      .limit(7)
      .get();

    const summaries: DailyMoodSummary[] = summariesSnap.docs.map(
      (d) => d.data() as DailyMoodSummary,
    );

    // Check daily AI budget before calling OpenAI
    const budgetResult = await checkDailyAiBudget(db, userId, REFLECTION_DAILY_AI_BUDGET);
    if (!budgetResult.allowed) {
      sendRateLimitResponse(res, 'dailyBudget', 0, { userId, endpoint: 'dailyReflection' });
      return;
    }

    // Generate reflection
    const reflection = await runReflectionAgent(summaries, openaiApiKey.value());
    const generatedAt = new Date().toISOString();
    const payload = { reflection, generatedAt, date: today };

    // Cache in Firestore
    await cacheRef.set(payload);

    logger.info("dailyReflection: generated and cached", { userId, today });
    return successResponse(res, payload);
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
