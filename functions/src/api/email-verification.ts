/**
 * Email verification by one-time code.
 *
 * POST /sendVerificationCode  - emails a fresh 6-digit code to the signed-in
 *   email/password account. Replaces Firebase's link email so users can
 *   finish verifying without leaving the app.
 * POST /verifyEmailCode { code } - checks the code and, when it matches,
 *   marks the Firebase Auth user's email as verified. The client must then
 *   refresh its ID token so later calls carry email_verified=true.
 *
 * Both endpoints accept unverified accounts (that is their whole purpose),
 * and both are no-ops for accounts that do not need verification.
 */

import { logger } from 'firebase-functions/v2';
import { onRequest } from 'firebase-functions/v2/https';
import { defineSecret } from 'firebase-functions/params';
import { FUNCTIONS_REVISION } from '../shared/version';
import { checkRateLimit, sendLimitCheckResponse } from '../shared/rate-limiter';
import type { RateLimitConfig } from '../shared/rate-limiter';
import { getAuthInstance, getDb, initializeFirebase } from '../shared/firebase';
import { requireAuth, verifyAppCheck, errorResponse, successResponse } from '../shared/auth';
import type { AuthenticatedRequest } from '../shared/auth';
import { AccountDeletingError } from '../shared/account-lifecycle';
import { safeErrorMetadata } from '../shared/safe-logging';
import emailVerification = require('../shared/email-verification');
initializeFirebase();

const resendApiKey = defineSecret('resend-api-key');
/** Sender, e.g. `WalkWorthy <verify@yourdomain.com>`, on a domain verified in Resend. */
const verificationEmailFrom = defineSecret('verification-email-from');

/** Sends are capped tightly: each one costs an email and can target an inbox. */
export const SEND_CODE_USER_LIMIT: RateLimitConfig = { maxRequests: 5, windowMs: 60 * 60 * 1000 };
/** Per-code attempts are capped separately; this bounds guessing across resends. */
export const VERIFY_CODE_USER_LIMIT: RateLimitConfig = { maxRequests: 20, windowMs: 60 * 60 * 1000 };

/** Only email/password accounts with an unverified address need a code. */
function needsVerification(auth: AuthenticatedRequest): boolean {
  return auth.user.firebase.sign_in_provider === 'password' && auth.user.email_verified !== true;
}

export const sendVerificationCode = onRequest(
  { maxInstances: 10, timeoutSeconds: 30, invoker: 'public', secrets: [resendApiKey, verificationEmailFrom] },
  async (req, res) => {
    logger.info('sendVerificationCode invoked', { revision: FUNCTIONS_REVISION });
    if (req.method !== 'POST') {
      res.setHeader('Allow', 'POST');
      return errorResponse(res, 405, 'Method not allowed');
    }
    if (!await verifyAppCheck(req, res)) return;
    const auth = await requireAuth(req, res, { allowUnverified: true });
    if (!auth) return;
    if (!needsVerification(auth)) return successResponse(res, { sent: false, alreadyVerified: true });
    const db = getDb();
    try {
      // Read the address from Auth, not the token, so a just-changed email is used.
      const email = (await getAuthInstance().getUser(auth.userId)).email;
      if (!email) return errorResponse(res, 400, 'This account has no email address');
      const limit = await checkRateLimit(db, `user:${auth.userId}:sendVerificationCode`, SEND_CODE_USER_LIMIT, auth.userId);
      if (!limit.allowed) return sendLimitCheckResponse(res, 'user', limit, { endpoint: 'sendVerificationCode' });
      const code = emailVerification.generateCode();
      await emailVerification.storeCode(db, auth.userId, email, code);
      await emailVerification.sendCodeEmail(resendApiKey.value(), verificationEmailFrom.value(), email, code);
      logger.info('Verification code sent');
      return successResponse(res, { sent: true });
    } catch (error) {
      if (error instanceof AccountDeletingError) return errorResponse(res, 403, 'Account deletion is in progress', undefined, 'ACCOUNT_DELETING');
      if (error instanceof emailVerification.EmailSendError) {
        logger.error('Verification email provider failed', { status: error.status });
      } else {
        logger.error('Verification code send failed', safeErrorMetadata(error));
      }
      return errorResponse(res, 503, "We couldn't send the email right now. Please try again in a minute.");
    }
  },
);

const OUTCOME_MESSAGES = {
  invalid: "That code doesn't match. Check the email and try again.",
  expired: 'That code has expired. Tap "Send a new code" to get another one.',
  tooManyAttempts: 'Too many incorrect tries. Tap "Send a new code" to get another one.',
} as const;

export const verifyEmailCode = onRequest({ maxInstances: 10, timeoutSeconds: 30, invoker: 'public' }, async (req, res) => {
  logger.info('verifyEmailCode invoked', { revision: FUNCTIONS_REVISION });
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return errorResponse(res, 405, 'Method not allowed');
  }
  if (!await verifyAppCheck(req, res)) return;
  const auth = await requireAuth(req, res, { allowUnverified: true });
  if (!auth) return;
  const code = emailVerification.validateCodeInput(req.body);
  if (!code) return errorResponse(res, 400, 'Enter the 6-digit code from the email.');
  const db = getDb();
  try {
    const user = await getAuthInstance().getUser(auth.userId);
    // The token can be stale: the account may already be verified (another
    // device, or an old link email). Treat that as success.
    if (!needsVerification(auth) || user.emailVerified) {
      await emailVerification.clearCode(db, auth.userId);
      return successResponse(res, { verified: true });
    }
    if (!user.email) return errorResponse(res, 400, 'This account has no email address');
    const limit = await checkRateLimit(db, `user:${auth.userId}:verifyEmailCode`, VERIFY_CODE_USER_LIMIT, auth.userId);
    if (!limit.allowed) return sendLimitCheckResponse(res, 'user', limit, { endpoint: 'verifyEmailCode' });
    const outcome = await emailVerification.checkCode(db, auth.userId, user.email, code);
    if (outcome !== 'verified') {
      logger.info('Verification code rejected', { outcome });
      return errorResponse(res, 400, OUTCOME_MESSAGES[outcome]);
    }
    await getAuthInstance().updateUser(auth.userId, { emailVerified: true });
    logger.info('Email verified by code');
    return successResponse(res, { verified: true });
  } catch (error) {
    if (error instanceof AccountDeletingError) return errorResponse(res, 403, 'Account deletion is in progress', undefined, 'ACCOUNT_DELETING');
    logger.error('Verification code check failed', safeErrorMetadata(error));
    return errorResponse(res, 503, 'Verification is unavailable right now. Please try again.');
  }
});
