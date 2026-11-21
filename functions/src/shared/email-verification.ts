import { createHmac, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import type { Firestore } from 'firebase-admin/firestore';
import { Timestamp } from 'firebase-admin/firestore';
import { assertAccountActive } from './account-lifecycle';

/** How long an emailed code stays valid. */
export const CODE_TTL_MS = 10 * 60 * 1000;
/** Wrong guesses allowed per code before a new one must be requested. */
export const MAX_CODE_ATTEMPTS = 5;
export const CODE_LENGTH = 6;

const CODE_RE = /^[0-9]{6}$/;

/**
 * Under the user's document so account deletion's recursive delete erases it.
 * Clients cannot read it (Firestore rules catch-all deny); only a salted hash
 * of the code is stored, never the code itself.
 */
export const verificationCodeRef = (db: Firestore, uid: string) =>
  db.collection('users').doc(uid).collection('emailVerification').doc('current');

interface StoredCode {
  hash: string;
  salt: string;
  email: string;
  attempts: number;
  expiresAt: Timestamp;
}

export type VerifyOutcome = 'verified' | 'invalid' | 'expired' | 'tooManyAttempts';

/** Uniformly random 6-digit code, zero-padded. */
export function generateCode(): string {
  return randomInt(0, 10 ** CODE_LENGTH).toString().padStart(CODE_LENGTH, '0');
}

function hashCode(code: string, salt: string): string {
  return createHmac('sha256', salt).update(code).digest('hex');
}

/** Accepts only a JSON body of `{ code: "123456" }`, whitespace trimmed. */
export function validateCodeInput(body: unknown): string | null {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return null;
  const b = body as Record<string, unknown>;
  if (Object.keys(b).some(k => k !== 'code')) return null;
  if (typeof b.code !== 'string') return null;
  const code = b.code.trim();
  return CODE_RE.test(code) ? code : null;
}

/**
 * Replaces any earlier code for this user, so only the newest email works.
 * The deletion barrier is read in the same transaction so a code cannot be
 * written after account deletion has started.
 */
export async function storeCode(db: Firestore, uid: string, email: string, code: string, now = Date.now()): Promise<void> {
  const salt = randomBytes(16).toString('hex');
  const doc: StoredCode = {
    hash: hashCode(code, salt),
    salt,
    email: email.toLowerCase(),
    attempts: 0,
    expiresAt: Timestamp.fromMillis(now + CODE_TTL_MS),
  };
  await db.runTransaction(async tx => {
    await assertAccountActive(db, uid, tx);
    tx.set(verificationCodeRef(db, uid), doc);
  });
}

/**
 * Checks a submitted code against the stored hash. A correct code is consumed
 * (deleted) so it cannot be replayed. Each wrong guess is counted, and the
 * code is discarded once MAX_CODE_ATTEMPTS is reached. The code is bound to
 * the address it was sent to, so changing the account email invalidates it.
 */
export async function checkCode(db: Firestore, uid: string, email: string, code: string, now = Date.now()): Promise<VerifyOutcome> {
  const ref = verificationCodeRef(db, uid);
  return db.runTransaction(async tx => {
    await assertAccountActive(db, uid, tx);
    const snap = await tx.get(ref);
    if (!snap.exists) return 'expired';
    const stored = snap.data() as StoredCode;
    if (stored.email !== email.toLowerCase() || stored.expiresAt.toMillis() <= now) {
      tx.delete(ref);
      return 'expired';
    }
    if (stored.attempts >= MAX_CODE_ATTEMPTS) {
      tx.delete(ref);
      return 'tooManyAttempts';
    }
    const expected = Buffer.from(stored.hash, 'hex');
    const actual = Buffer.from(hashCode(code, stored.salt), 'hex');
    if (expected.length === actual.length && timingSafeEqual(expected, actual)) {
      tx.delete(ref);
      return 'verified';
    }
    const attempts = stored.attempts + 1;
    if (attempts >= MAX_CODE_ATTEMPTS) {
      tx.delete(ref);
      return 'tooManyAttempts';
    }
    tx.update(ref, { attempts });
    return 'invalid';
  });
}

/** Removes any outstanding code, e.g. after the account was verified another way. */
export async function clearCode(db: Firestore, uid: string): Promise<void> {
  await verificationCodeRef(db, uid).delete();
}

/** Thrown when the mail provider rejects or cannot be reached. Carries no provider text. */
export class EmailSendError extends Error {
  constructor(readonly status?: number) { super('Verification email could not be sent'); }
}

const RESEND_ENDPOINT = 'https://api.resend.com/emails';

/**
 * Sends the code through Resend's HTTP API. The code is placed in the subject
 * too so it shows in the iOS notification banner and Mail can offer it as an
 * AutoFill suggestion above the keyboard.
 */
export async function sendCodeEmail(apiKey: string, from: string, to: string, code: string): Promise<void> {
  const minutes = Math.round(CODE_TTL_MS / 60000);
  const text = [
    `Your WalkWorthy verification code is ${code}.`,
    '',
    `Enter it in the app to finish setting up your account. It expires in ${minutes} minutes.`,
    '',
    "If you didn't create a WalkWorthy account, you can ignore this email.",
  ].join('\n');
  const html = `<p>Your WalkWorthy verification code is</p>`
    + `<p style="font-size:32px;font-weight:bold;letter-spacing:6px;margin:16px 0">${code}</p>`
    + `<p>Enter it in the app to finish setting up your account. It expires in ${minutes} minutes.</p>`
    + `<p style="color:#666">If you didn't create a WalkWorthy account, you can ignore this email.</p>`;
  let response: globalThis.Response;
  try {
    response = await fetch(RESEND_ENDPOINT, {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from, to: [to], subject: `${code} is your WalkWorthy code`, text, html }),
      signal: AbortSignal.timeout(10_000),
    });
  } catch {
    throw new EmailSendError();
  }
  if (!response.ok) throw new EmailSendError(response.status);
}
