import type { Firestore } from 'firebase-admin/firestore';
import type { Request, Response } from 'express';
import { logger } from 'firebase-functions/v2';

export interface RateLimitConfig {
  maxRequests: number;
  windowMs: number;
}

export interface RateLimitResult {
  allowed: boolean;
  retryAfterSeconds: number;
}

export interface DailyBudgetResult {
  allowed: boolean;
  remaining: number;
}

export type RateLimitScope = 'user' | 'ip' | 'dailyBudget';

export const RATE_LIMIT_SCHEMA_VERSION = 1 as const;

export interface RateLimitErrorResponse {
  error: string;
  code: 'RATE_LIMITED';
  scope: RateLimitScope;
  retryAfterSeconds: number;
}

/**
 * Sends a structured 429 response and logs the rate-limit event.
 */
export function sendRateLimitResponse(
  res: Response,
  scope: RateLimitScope,
  retryAfterSeconds: number,
  context: { userId?: string; endpoint: string }
): void {
  logger.warn('Rate limit exceeded', {
    userId: context.userId,
    endpoint: context.endpoint,
    scope,
    retryAfterSeconds,
  });

  res.set('Retry-After', String(retryAfterSeconds));

  const body: RateLimitErrorResponse = {
    error: 'Too many requests. Please try again later.',
    code: 'RATE_LIMITED',
    scope,
    retryAfterSeconds,
  };

  res.status(429).json(body);
}

interface RateLimitDoc {
  timestamps: string[];
  updatedAt: string;
}

interface DailyBudgetDoc {
  callCount: number;
  date: string;
}

// AI endpoints (expensive)
export const MOOD_CHECKIN_USER_LIMIT: RateLimitConfig = { maxRequests: 10, windowMs: 3600000 };
export const MOOD_CHECKIN_IP_LIMIT: RateLimitConfig = { maxRequests: 30, windowMs: 3600000 };
export const DAILY_REFLECTION_USER_LIMIT: RateLimitConfig = { maxRequests: 5, windowMs: 3600000 };
export const DAILY_REFLECTION_IP_LIMIT: RateLimitConfig = { maxRequests: 20, windowMs: 3600000 };

// Standard endpoints
export const STANDARD_USER_LIMIT: RateLimitConfig = { maxRequests: 30, windowMs: 3600000 };
export const STANDARD_IP_LIMIT: RateLimitConfig = { maxRequests: 60, windowMs: 3600000 };

// Daily AI budgets
export const MOOD_DAILY_AI_BUDGET = 15;
export const REFLECTION_DAILY_AI_BUDGET = 5;

/**
 * Sliding window rate limiter backed by Firestore.
 * Stores ISO timestamps of recent requests and filters out expired ones.
 */
export async function checkRateLimit(
  db: Firestore,
  key: string,
  config: RateLimitConfig
): Promise<RateLimitResult> {
  const docRef = db.collection('_rateLimits').doc(key);
  const now = Date.now();
  const windowStart = now - config.windowMs;

  try {
    return await db.runTransaction(async (tx) => {
      const snap = await tx.get(docRef);
      const data = snap.exists ? (snap.data() as RateLimitDoc) : null;

      const allTimestamps: string[] = data?.timestamps ?? [];
      const windowTimestamps = allTimestamps.filter(
        (ts) => new Date(ts).getTime() > windowStart
      );

      if (windowTimestamps.length >= config.maxRequests) {
        const oldestInWindow = windowTimestamps.reduce((min, ts) => {
          const t = new Date(ts).getTime();
          return t < min ? t : min;
        }, Infinity);
        const retryAfterMs = oldestInWindow + config.windowMs - now;
        const retryAfterSeconds = Math.ceil(Math.max(retryAfterMs, 0) / 1000);
        return { allowed: false, retryAfterSeconds };
      }

      const nowIso = new Date(now).toISOString();
      const updatedTimestamps = [...windowTimestamps, nowIso];
      const updatedDoc: RateLimitDoc = {
        timestamps: updatedTimestamps,
        updatedAt: nowIso,
      };
      tx.set(docRef, updatedDoc);

      return { allowed: true, retryAfterSeconds: 0 };
    });
  } catch (err) {
    logger.error('checkRateLimit transaction failed', { key, err });
    // Fail open to avoid blocking legitimate requests on Firestore errors
    return { allowed: true, retryAfterSeconds: 0 };
  }
}

/**
 * Daily AI budget counter backed by Firestore.
 * Tracks per-user call counts scoped to a UTC calendar day.
 */
export async function checkDailyAiBudget(
  db: Firestore,
  userId: string,
  maxCallsPerDay: number
): Promise<DailyBudgetResult> {
  const today = new Date().toISOString().slice(0, 10); // YYYY-MM-DD UTC
  const docId = `${userId}_${today}`;
  const docRef = db.collection('_dailyBudgets').doc(docId);

  try {
    return await db.runTransaction(async (tx) => {
      const snap = await tx.get(docRef);

      if (!snap.exists) {
        const newDoc: DailyBudgetDoc = { callCount: 1, date: today };
        tx.set(docRef, newDoc);
        return { allowed: true, remaining: maxCallsPerDay - 1 };
      }

      const data = snap.data() as DailyBudgetDoc;

      if (data.date !== today) {
        // Stale document from a previous day — reset
        const resetDoc: DailyBudgetDoc = { callCount: 1, date: today };
        tx.set(docRef, resetDoc);
        return { allowed: true, remaining: maxCallsPerDay - 1 };
      }

      if (data.callCount >= maxCallsPerDay) {
        return { allowed: false, remaining: 0 };
      }

      const updatedCount = data.callCount + 1;
      tx.update(docRef, { callCount: updatedCount });
      return { allowed: true, remaining: maxCallsPerDay - updatedCount };
    });
  } catch (err) {
    logger.error('checkDailyAiBudget transaction failed', { userId, err });
    // Fail open to avoid blocking legitimate requests on Firestore errors
    return { allowed: true, remaining: 0 };
  }
}

/**
 * Extracts the client IP from an Express request.
 * Prefers the first address in X-Forwarded-For, falls back to req.ip.
 */
export function getClientIp(req: Request): string {
  const forwarded = req.headers['x-forwarded-for'];
  if (forwarded) {
    const raw = Array.isArray(forwarded) ? forwarded[0] : forwarded;
    const first = raw.split(',')[0].trim();
    if (first) return first;
  }
  return req.ip ?? 'unknown';
}
