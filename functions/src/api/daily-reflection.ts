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
import { requireAuth, errorResponse, successResponse } from "../shared/auth";
import { runReflectionAgent } from "../lib/reflection-agent";
import type { DailyMoodSummary } from "../shared/types";

initializeFirebase();

const openaiApiKey = defineSecret("openai-api-key");

const httpsOptions: HttpsOptions = {
  maxInstances: 10,
  timeoutSeconds: 60,
  invoker: "public",
  secrets: [openaiApiKey],
};

function getTodayString(): string {
  return new Date().toISOString().split("T")[0];
}

function getSevenDaysAgoString(): string {
  const d = new Date();
  d.setDate(d.getDate() - 6);
  return d.toISOString().split("T")[0];
}

export const dailyReflection = onRequest(httpsOptions, async (req, res) => {
  logger.info("dailyReflection invoked", { method: req.method });

  if (req.method !== "GET") {
    res.setHeader("Allow", "GET");
    return errorResponse(res, 405, "Method not allowed");
  }

  return handleGet(req, res);
});

async function handleGet(req: Request, res: Response): Promise<void> {
  const authReq = await requireAuth(req, res);
  if (!authReq) return;

  const { userId } = authReq;
  const db = getDb();
  const today = getTodayString();

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
      .where("date", ">=", getSevenDaysAgoString())
      .where("date", "<=", today)
      .orderBy("date", "desc")
      .limit(7)
      .get();

    const summaries: DailyMoodSummary[] = summariesSnap.docs.map(
      (d) => d.data() as DailyMoodSummary,
    );

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
