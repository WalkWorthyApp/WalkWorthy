import type { Firestore } from 'firebase-admin/firestore';
import { Timestamp, FieldValue } from 'firebase-admin/firestore';
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
  /**
   * Hint passed to `Retry-After` on 429 responses. Zero (the normal case)
   * means the user has exhausted their daily quota and should wait until the
   * day rolls over. A non-zero value is returned when the budget check itself
   * failed (fail-closed) so the client can retry shortly.
   */
  retryAfterSeconds: number;
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
  expiresAt?: FirebaseFirestore.Timestamp;
}

interface DailyBudgetDoc {
  callCount: number;
  date: string;
  expiresAt?: FirebaseFirestore.Timestamp;
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
      // Firestore TTL policy on `_rateLimits.expiresAt` auto-deletes stale docs — see README / Firestore Console.
      const updatedDoc: RateLimitDoc = {
        timestamps: updatedTimestamps,
        updatedAt: nowIso,
        expiresAt: Timestamp.fromMillis(now + config.windowMs + 60 * 60 * 1000),
      };
      tx.set(docRef, updatedDoc);

      return { allowed: true, retryAfterSeconds: 0 };
    });
  } catch (err) {
    logger.error('Rate limit check failed', {
      code: 'RATE_LIMIT_CHECK_FAILED',
      key,
      error: err instanceof Error ? err.message : String(err),
    });
    // Fail open for per-user sliding window: blocking legitimate users on
    // transient Firestore errors is worse than allowing one extra request.
    // Distinct error code (above) enables targeted alerting.
    return { allowed: true, retryAfterSeconds: 0 };
  }
}

/**
 * Returns today's date string in UTC (YYYY-MM-DD). Shared between
 * `checkDailyAiBudget` and `refundDailyAiBudget` to keep the document ID
 * identical across reserve/refund calls.
 */
export function getTodayUtcDateString(): string {
  return new Date().toISOString().slice(0, 10);
}

/**
 * Daily AI budget counter backed by Firestore.
 * Tracks per-user call counts scoped to a UTC calendar day.
 *
 * FAILS CLOSED: because this function gates OpenAI spend, any Firestore
 * transaction error MUST deny the request. Failing open would allow an
 * attacker to bypass spend caps by inducing transient Firestore errors.
 */
export async function checkDailyAiBudget(
  db: Firestore,
  userId: string,
  maxCallsPerDay: number
): Promise<DailyBudgetResult> {
  const today = getTodayUtcDateString();
  const docId = `${userId}_${today}`;
  const docRef = db.collection('_dailyBudgets').doc(docId);

  try {
    return await db.runTransaction(async (tx) => {
      const snap = await tx.get(docRef);

      // Firestore TTL policy on `_dailyBudgets.expiresAt` auto-deletes stale docs — see README / Firestore Console.
      const expiresAt = Timestamp.fromMillis(Date.now() + 48 * 60 * 60 * 1000);

      if (!snap.exists) {
        const newDoc: DailyBudgetDoc = { callCount: 1, date: today, expiresAt };
        tx.set(docRef, newDoc);
        return { allowed: true, remaining: maxCallsPerDay - 1, retryAfterSeconds: 0 };
      }

      const data = snap.data() as DailyBudgetDoc;

      if (data.date !== today) {
        // Stale document from a previous day — reset
        const resetDoc: DailyBudgetDoc = { callCount: 1, date: today, expiresAt };
        tx.set(docRef, resetDoc);
        return { allowed: true, remaining: maxCallsPerDay - 1, retryAfterSeconds: 0 };
      }

      if (data.callCount >= maxCallsPerDay) {
        return { allowed: false, remaining: 0, retryAfterSeconds: 0 };
      }

      const updatedCount = data.callCount + 1;
      tx.update(docRef, { callCount: updatedCount, expiresAt });
      return { allowed: true, remaining: maxCallsPerDay - updatedCount, retryAfterSeconds: 0 };
    });
  } catch (err) {
    logger.error('AI budget check failed', {
      userId,
      error: err instanceof Error ? err.message : String(err),
    });
    // FAIL CLOSED: denying the request is the safe default when we cannot
    // verify the user is within their daily spend cap. Give the client a
    // short retry window so the eventual consistency can clear.
    return { allowed: false, remaining: 0, retryAfterSeconds: 60 };
  }
}

/**
 * Compensating decrement for a previously-reserved daily AI budget slot.
 *
 * Called from API handlers when the work that was charged against the budget
 * (OpenAI call, Firestore write) failed, so the user is not penalized by
 * server-side errors. Uses `FieldValue.increment(-1)` for an atomic,
 * transaction-free refund; missing documents are ignored (nothing to refund).
 *
 * Intentionally best-effort: a failure here is logged but must not propagate
 * further, because the caller is already in an error path.
 */
export async function refundDailyAiBudget(
  db: Firestore,
  userId: string,
  todayDate: string
): Promise<void> {
  const docId = `${userId}_${todayDate}`;
  const docRef = db.collection('_dailyBudgets').doc(docId);
  try {
    // Use a transaction so we never decrement below 0 or a document
    // belonging to a different day (rollover between reserve and refund).
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(docRef);
      if (!snap.exists) return;
      const data = snap.data() as DailyBudgetDoc;
      if (data.date !== todayDate) return;
      if (typeof data.callCount !== 'number' || data.callCount <= 0) return;
      tx.update(docRef, { callCount: FieldValue.increment(-1) });
    });
    logger.info('AI budget refunded', { userId, date: todayDate });
  } catch (err) {
    logger.error('AI budget refund failed', {
      userId,
      date: todayDate,
      error: err instanceof Error ? err.message : String(err),
    });
    // Intentionally swallow — caller is already handling an error path.
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
