import { assertAccountActive, AccountDeletingError } from './account-lifecycle';
import type { Firestore } from 'firebase-admin/firestore';
import { Timestamp, FieldValue } from 'firebase-admin/firestore';
import type { Response } from 'express';
import { logger } from 'firebase-functions/v2';
import { safeErrorMetadata } from './safe-logging';
import { errorResponse } from './auth';

export interface RateLimitConfig {
  maxRequests: number;
  windowMs: number;
}
export interface RateLimitResult {
  allowed: boolean;
  retryAfterSeconds: number;
  /** Failed checks deny access without claiming the user's quota is exhausted. */
  failure?: 'unavailable' | 'accountDeleting';
}

export interface DailyBudgetResult extends RateLimitResult {
  remaining: number;
  /**
   * Zero for exhausted daily quota (429). An unavailable check carries a
   * short retry delay alongside failure:'unavailable' and maps to 503.
   */
  retryAfterSeconds: number;
}

export type RateLimitScope = 'user' | 'dailyBudget';

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
  logger.warn('Rate limit exceeded', { endpoint: context.endpoint, scope, retryAfterSeconds });

  res.set('Retry-After', String(retryAfterSeconds));

  const body: RateLimitErrorResponse = {
    error: 'Too many requests. Please try again later.',
    code: 'RATE_LIMITED',
    scope,
    retryAfterSeconds,
  };

  res.status(429).json(body);
}

/** Keep database failures and deletion barriers distinct from actual quota use. */
export function sendLimitCheckResponse(
  res: Response,
  scope: RateLimitScope,
  result: RateLimitResult,
  context: { userId?: string; endpoint: string },
): void {
  if (result.failure === 'accountDeleting') {
    return errorResponse(res, 403, 'Account deletion is in progress', undefined, 'ACCOUNT_DELETING');
  }
  if (result.failure === 'unavailable') {
    res.set('Retry-After', String(result.retryAfterSeconds));
    return errorResponse(res, 503, 'Service temporarily unavailable; please retry', undefined, 'LIMIT_CHECK_UNAVAILABLE');
  }
  return sendRateLimitResponse(res, scope, result.retryAfterSeconds, context);
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
export const DAILY_REFLECTION_USER_LIMIT: RateLimitConfig = { maxRequests: 5, windowMs: 3600000 };

// Standard endpoints
export const STANDARD_USER_LIMIT: RateLimitConfig = { maxRequests: 30, windowMs: 3600000 };

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
  config: RateLimitConfig,
  userId: string,
  options?: { allowDuringDeletion?: boolean }
): Promise<RateLimitResult> {
  if (!key.startsWith('user:')) throw new Error('Only authenticated rate limits supported');
  if (!key.startsWith(`user:${userId}:`)) throw new Error('Rate limit owner mismatch');
  const docRef = db.collection('_rateLimits').doc(key);
  const now = Date.now();
  const windowStart = now - config.windowMs;

  try {
    return await db.runTransaction(async (tx) => {
      // `deleteAccount` must stay throttled while the deletion barrier exists,
      // because a failed cleanup is retried against the SAME marker. Applying
      // the barrier here would reject every retry and strand the account, so
      // that one caller opts out of the barrier while keeping the limit.
      if (options?.allowDuringDeletion !== true) {
        await assertAccountActive(db, userId, tx);
      }
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
    if (err instanceof AccountDeletingError) return { allowed: false, retryAfterSeconds: 0, failure: 'accountDeleting' };
    logger.error('Rate limit check failed', safeErrorMetadata(err));
    return { allowed: false, retryAfterSeconds: 60, failure: 'unavailable' };
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
      await assertAccountActive(db, userId, tx);
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
    if (err instanceof AccountDeletingError) return { allowed: false, remaining: 0, retryAfterSeconds: 0, failure: 'accountDeleting' };
    logger.error('AI budget check failed', safeErrorMetadata(err));
    // FAIL CLOSED: denying the request is the safe default when we cannot
    // verify the user is within their daily spend cap. Give the client a
    // short retry window so the eventual consistency can clear.
    return { allowed: false, remaining: 0, retryAfterSeconds: 60, failure: 'unavailable' };
  }
}

/**
 * Compensating decrement for a previously-reserved daily AI budget slot.
 *
 * Called from API handlers when the work that was charged against the budget
 * (OpenAI call, Firestore write) failed, so the user is not penalized by
 * server-side errors. Uses `FieldValue.increment(-1)` for an atomic,
 * guarded refund; missing documents are ignored (nothing to refund).
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
      await assertAccountActive(db, userId, tx);
      const snap = await tx.get(docRef);
      if (!snap.exists) return;
      const data = snap.data() as DailyBudgetDoc;
      if (data.date !== todayDate) return;
      if (typeof data.callCount !== 'number' || data.callCount <= 0) return;
      tx.update(docRef, { callCount: FieldValue.increment(-1) });
    });
    logger.info('AI budget refunded');
  } catch (err) {
    logger.error('AI budget refund failed', safeErrorMetadata(err));
    // Intentionally swallow — caller is already handling an error path.
  }
}
