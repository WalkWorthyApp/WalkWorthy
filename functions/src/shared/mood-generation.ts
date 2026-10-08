import { createHash, randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { Timestamp, type DocumentReference, type Firestore, type Transaction } from 'firebase-admin/firestore';
import { assertAccountActive } from './account-lifecycle';
import { AiConsentRequiredError } from './privacy-consent';
import { MOOD_DAILY_AI_BUDGET, type DailyBudgetResult } from './rate-limiter';
import type { MoodCheckInResponse, MoodSpectrumData } from './types';

// Longer than the HTTP function's 60s deadline. Expiry is recovery, not proof
// that an external request did no work: started attempts never get refunded.
export const MOOD_CLAIM_LEASE_MS = 90_000;
const WAIT_MS = 20_000;

export class MoodGenerationUnavailableError extends Error {}
export class MoodGenerationConflictError extends Error {}

export interface MoodGenerationIdentity {
  checkInDocId: string;
  input: MoodSpectrumData;
  regenerate: boolean;
  // Record identity is stable across regenerations; updateTime distinguishes
  // later deliberate generations from followers of the same observed version.
  baseVersion: string;
  profileContext: unknown;
}

export interface MoodGenerationClaim {
  ref: DocumentReference;
  owner: string;
  budgetDate: string;
  userId: string;
}

interface ClaimData {
  owner: string;
  baseVersion: string;
  status: 'pending' | 'completed' | 'failed';
  leaseUntil: Timestamp;
  budgetDate: string;
  consumed: boolean;
  response?: MoodCheckInResponse;
  failure?: 'consent' | 'conflict' | 'failed';
}

type ClaimResult =
  | { type: 'owner' | 'follower'; claim: MoodGenerationClaim }
  | { type: 'completed'; response: MoodCheckInResponse }
  | { type: 'denied'; budget: DailyBudgetResult };

/** Private, user-scoped records contain hashes, not the submitted note/profile.
 * A new observed record version permits another deliberate regeneration. */
export function moodGenerationRef(db: Firestore, userId: string, identity: MoodGenerationIdentity): DocumentReference {
  const { input } = identity;
  const digest = createHash('sha256').update(JSON.stringify([
    identity.checkInDocId, identity.regenerate, identity.baseVersion, input.moodScore,
    input.followUpScore, input.note, [...input.emotionTags].sort(),
    [...input.impactCategories].sort(), identity.profileContext,
  ])).digest('hex');
  return db.collection('users').doc(userId).collection('moodGenerationClaims').doc(digest);
}

const budgetRef = (db: Firestore, userId: string, date: string) =>
  db.collection('_dailyBudgets').doc(`${userId}_${date}`);

function countForDate(data: FirebaseFirestore.DocumentData | undefined, date: string): number {
  if (!data || data.date !== date) return 0;
  if (!Number.isSafeInteger(data.callCount) || data.callCount < 0) throw new MoodGenerationUnavailableError();
  return data.callCount as number;
}

/** Admission and reservation must commit together: followers never reserve.
 * This uses the existing per-user UTC budget and its unchanged mood limit. */
export async function claimMoodGeneration(
  db: Firestore, userId: string, identity: MoodGenerationIdentity,
): Promise<ClaimResult> {
  const ref = moodGenerationRef(db, userId, identity);
  const owner = randomUUID();
  return db.runTransaction(async tx => {
    await assertAccountActive(db, userId, tx);
    const current = (await tx.get(ref)).data() as ClaimData | undefined;
    const now = Date.now();
    if (current?.status === 'pending' && current.leaseUntil.toMillis() > now) {
      return { type: 'follower', claim: { ref, userId, owner: current.owner, budgetDate: current.budgetDate } };
    }
    if (current?.status === 'completed' && current.baseVersion === identity.baseVersion && current.response) {
      return { type: 'completed', response: current.response };
    }

    // Capture the date inside the successful transaction, including retries.
    const budgetDate = new Date(now).toISOString().slice(0, 10);
    const reservationRef = budgetRef(db, userId, budgetDate);
    const reservation = await tx.get(reservationRef);
    let count = countForDate(reservation.data(), budgetDate);
    const refundExpired = current?.status === 'pending' && current.consumed === false;
    const oldBudgetRef = refundExpired ? budgetRef(db, userId, current.budgetDate) : undefined;
    const oldBudget = oldBudgetRef && current?.budgetDate !== budgetDate ? await tx.get(oldBudgetRef) : undefined;
    if (refundExpired && current.budgetDate === budgetDate) count = Math.max(0, count - 1);
    if (count >= MOOD_DAILY_AI_BUDGET) {
      return { type: 'denied', budget: { allowed: false, remaining: 0, retryAfterSeconds: 0 } };
    }
    if (oldBudget && oldBudgetRef && current) {
      const oldCount = countForDate(oldBudget.data(), current.budgetDate);
      if (oldCount > 0) tx.update(oldBudgetRef, { callCount: oldCount - 1 });
    }
    tx.set(reservationRef, { callCount: count + 1, date: budgetDate,
      expiresAt: Timestamp.fromMillis(now + 48 * 60 * 60 * 1000) });
    tx.set(ref, { owner, baseVersion: identity.baseVersion, status: 'pending', budgetDate,
      consumed: false, leaseUntil: Timestamp.fromMillis(now + MOOD_CLAIM_LEASE_MS) } satisfies ClaimData);
    return { type: 'owner', claim: { ref, owner, userId, budgetDate } };
  });
}

/** A stale worker can neither dispatch another model attempt nor publish. */
async function ownedClaim(tx: Transaction, claim: MoodGenerationClaim): Promise<ClaimData> {
  await assertAccountActive(claim.ref.firestore, claim.userId, tx);
  const data = (await tx.get(claim.ref)).data() as ClaimData | undefined;
  if (!data || data.owner !== claim.owner || data.status !== 'pending' ||
      data.leaseUntil.toMillis() <= Date.now()) throw new MoodGenerationConflictError();
  return data;
}

/** Persist before dispatch, including retries. Unknown provider outcomes count.
 * One daily unit remains one generation operation with the existing bounded
 * agent retries; this counter does not represent tokens or exact billed cost. */
export async function markMoodGenerationConsumed(claim: MoodGenerationClaim): Promise<void> {
  await claim.ref.firestore.runTransaction(async tx => {
    await ownedClaim(tx, claim);
    tx.update(claim.ref, { consumed: true });
  });
}

/** Read settlement state before any final check-in/summary transaction writes. */
export async function readMoodGenerationSettlement(tx: Transaction, claim: MoodGenerationClaim) {
  const data = await ownedClaim(tx, claim);
  const ref = budgetRef(claim.ref.firestore, claim.userId, claim.budgetDate);
  const budget = data.consumed === false ? await tx.get(ref) : undefined;
  return { data, ref, refundCount: budget ? countForDate(budget.data(), claim.budgetDate) : 0 };
}

export function completeMoodGeneration(
  tx: Transaction, claim: MoodGenerationClaim,
  settlement: Awaited<ReturnType<typeof readMoodGenerationSettlement>>, response: MoodCheckInResponse,
): void {
  // A fixed input-safety response did not dispatch generation. Successful and
  // failed consumed work both retain their original reservation.
  if (settlement.data.consumed === false && settlement.refundCount > 0) {
    tx.update(settlement.ref, { callCount: settlement.refundCount - 1 });
  }
  tx.update(claim.ref, { status: 'completed', response });
}

/** Compensate once, only while still the owner. Never delete a successor's
 * record or refund work after dispatch, even if persistence/consent failed. */
export async function failMoodGeneration(claim: MoodGenerationClaim, failure: ClaimData['failure'] = 'failed'): Promise<void> {
  const db = claim.ref.firestore;
  await db.runTransaction(async tx => {
    await assertAccountActive(db, claim.userId, tx);
    const data = (await tx.get(claim.ref)).data() as ClaimData | undefined;
    if (!data || data.owner !== claim.owner || data.status !== 'pending') return;
    const ref = budgetRef(db, claim.userId, claim.budgetDate);
    const budget = data.consumed === false ? await tx.get(ref) : undefined;
    const count = budget ? countForDate(budget.data(), claim.budgetDate) : 0;
    if (count > 0) tx.update(ref, { callCount: count - 1 });
    tx.update(claim.ref, { status: 'failed', failure });
  });
}

/** Followers only read the operation they joined. A replacement is not their
 * response. Waiting is bounded below the client and function deadlines. */
export async function waitForMoodGeneration(claim: MoodGenerationClaim): Promise<MoodCheckInResponse> {
  const deadline = Date.now() + WAIT_MS;
  while (Date.now() < deadline) {
    await assertAccountActive(claim.ref.firestore, claim.userId);
    const data = (await claim.ref.get()).data() as ClaimData | undefined;
    if (!data || data.owner !== claim.owner) throw new MoodGenerationConflictError();
    if (data.status === 'completed' && data.response) return data.response;
    if (data.status === 'failed') {
      if (data.failure === 'consent') throw new AiConsentRequiredError();
      if (data.failure === 'conflict') throw new MoodGenerationConflictError();
      throw new Error('Mood generation failed');
    }
    if (data.leaseUntil.toMillis() <= Date.now()) throw new MoodGenerationUnavailableError();
    await delay(100);
  }
  throw new MoodGenerationUnavailableError();
}
