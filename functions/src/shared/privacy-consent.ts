import type { Firestore, Transaction } from 'firebase-admin/firestore';
import { assertAccountActive } from './account-lifecycle';
export const NOTICE_VERSION = '2026-09-04';
export interface PrivacyConsent {
  aiSharing: boolean;
  noticeVersion: string;
  /** WalkWorthy is an adults-only service. '13-17' is retained only so
   *  pre-launch records still decode; it is never a valid grant. */
  ageGroup: '13-17' | '18+' | 'unknown';
  revision: number;
  updatedAt: string | null;
}
export const consentRef = (db: Firestore, uid: string) => db.collection('users').doc(uid).collection('privacy').doc('consent');
export function parseConsent(data?: Record<string, unknown>): PrivacyConsent {
  return {
    aiSharing: data?.aiSharing === true && data?.noticeVersion === NOTICE_VERSION &&
      Number.isSafeInteger(data?.revision) && Number(data?.revision) > 0 &&
      data?.ageGroup === '18+',
    noticeVersion: typeof data?.noticeVersion === 'string' ? data.noticeVersion : NOTICE_VERSION,
    ageGroup: data?.ageGroup === '13-17' || data?.ageGroup === '18+' ? data.ageGroup : 'unknown',
    revision: Number.isSafeInteger(data?.revision) && Number(data?.revision) >= 0 ? Number(data?.revision) : 0,
    updatedAt: typeof data?.updatedAt === 'string' ? data.updatedAt : null,
  };
}
export class AiConsentRequiredError extends Error {
  constructor() { super('Current AI sharing consent required'); }
}
export async function requireAiConsent(db: Firestore, uid: string, tx?: Transaction, expectedRevision?: number): Promise<PrivacyConsent> {
  await assertAccountActive(db, uid, tx);
  const ref = consentRef(db, uid);
  const snap = tx ? await tx.get(ref) : await ref.get();
  const consent = parseConsent(snap.data());
  if (!consent.aiSharing || consent.noticeVersion !== NOTICE_VERSION || consent.ageGroup !== '18+' ||
      (expectedRevision !== undefined && consent.revision !== expectedRevision)) throw new AiConsentRequiredError();
  return consent;
}
export type ConsentInput =
  | {aiSharing: true; noticeVersion: typeof NOTICE_VERSION; ageGroup: '18+'; expectedRevision: number}
  | {aiSharing: false; withdrawalId?: string};

export class ConsentConflict extends Error {}

export function validateConsentInput(body: unknown): ConsentInput | null {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return null;
  const b = body as Record<string, unknown>;
  if (Object.keys(b).some(k => !['aiSharing','noticeVersion','ageGroup','expectedRevision','withdrawalId'].includes(k)) ||
      typeof b.aiSharing !== 'boolean') return null;
  // Older clients include notice/revision fields on withdrawal. They may be
  // stale, but they must not prevent a user from stopping sharing.
  if (!b.aiSharing) {
    if ((b.noticeVersion !== undefined && typeof b.noticeVersion !== 'string') ||
        (b.ageGroup !== undefined && (typeof b.ageGroup !== 'string' || !['18+', '13-17', 'unknown'].includes(b.ageGroup))) ||
        (b.expectedRevision !== undefined && (!Number.isSafeInteger(b.expectedRevision) || Number(b.expectedRevision) < 0))) return null;
    if (b.withdrawalId !== undefined && (typeof b.withdrawalId !== 'string' ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(b.withdrawalId))) return null;
    return b.withdrawalId === undefined ? {aiSharing: false}
      : {aiSharing: false, withdrawalId: (b.withdrawalId as string).toLowerCase()};
  }
  if (b.withdrawalId !== undefined || b.noticeVersion !== NOTICE_VERSION ||
      !Number.isSafeInteger(b.expectedRevision) || Number(b.expectedRevision) < 0 ||
      Number(b.expectedRevision) >= Number.MAX_SAFE_INTEGER ||
      b.ageGroup !== '18+') return null;
  return {aiSharing: true, noticeVersion: NOTICE_VERSION, ageGroup: '18+', expectedRevision: Number(b.expectedRevision)};
}

/** Grants compare-and-set; withdrawal always stops the current grant. */
export async function savePrivacyConsent(db: Firestore, uid: string, input: ConsentInput): Promise<PrivacyConsent> {
  return db.runTransaction(async tx => {
    await assertAccountActive(db, uid, tx);
    const ref = consentRef(db, uid);
    const snapshot = await tx.get(ref);
    const raw = snapshot.data();
    const current = parseConsent(raw);
    if (input.aiSharing && current.revision !== input.expectedRevision) throw new ConsentConflict();
    // Only a retry of the same operation may reuse a revision. A NEW withdrawal
    // must invalidate grants that read the current false record before this choice.
    // Legacy clients without an identity conservatively advance on every request.
    // A subsequent grant removes the identity, so delayed retries still revoke it.
    if (!input.aiSharing && input.withdrawalId && raw?.aiSharing === false &&
        raw.withdrawalId === input.withdrawalId && current.revision > 0) return current;
    const next: PrivacyConsent = {
      aiSharing: input.aiSharing,
      noticeVersion: NOTICE_VERSION,
      ageGroup: input.aiSharing ? input.ageGroup : current.ageGroup,
      revision: current.revision + 1,
      updatedAt: new Date().toISOString(),
    };
    tx.set(ref, !input.aiSharing && input.withdrawalId
      ? {...next, withdrawalId: input.withdrawalId} : next);
    return next;
  });
}
