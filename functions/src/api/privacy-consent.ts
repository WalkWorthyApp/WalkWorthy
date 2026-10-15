import { logger } from 'firebase-functions/v2';
import { FUNCTIONS_REVISION } from '../shared/version';
import { checkRateLimit, sendLimitCheckResponse, STANDARD_USER_LIMIT } from '../shared/rate-limiter';
import { onRequest } from 'firebase-functions/v2/https';
import { getDb, initializeFirebase } from '../shared/firebase';
import { requireAuth, verifyAppCheck, errorResponse, successResponse } from '../shared/auth';
import { AccountDeletingError } from '../shared/account-lifecycle';
import { safeErrorMetadata } from '../shared/safe-logging';
import { consentRef, parseConsent, validateConsentInput, savePrivacyConsent, ConsentConflict, isOutdatedNoticeGrant } from '../shared/privacy-consent';
initializeFirebase();
export const PRIVACY_CONSENT_READ_LIMIT = {maxRequests: 300, windowMs: 60 * 60 * 1000};
export const privacyConsent = onRequest({maxInstances: 10, invoker: 'public'}, async (req, res) => {
  logger.info('privacyConsent invoked', { revision: FUNCTIONS_REVISION });
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'GET' && req.method !== 'PUT') {
    res.setHeader('Allow', 'GET, PUT');
    return errorResponse(res, 405, 'Method not allowed');
  }
  if (!await verifyAppCheck(req, res)) return;
  const auth = await requireAuth(req, res, {allowUnverified: true});
  if (!auth) return;
  const db = getDb();
  const ref = consentRef(db, auth.userId);
  try {
    const input = req.method === 'PUT' ? validateConsentInput(req.body) : null;
    if (req.method === 'PUT' && !input) {
      if (isOutdatedNoticeGrant(req.body)) {
        return errorResponse(res, 409, 'This version of WalkWorthy is out of date. Update the app to continue.', undefined, 'NOTICE_OUTDATED');
      }
      return errorResponse(res, 400, 'Invalid consent data');
    }
    // Withdrawal is never refused. Its own bucket only bounds repeat work: past
    // it, a withdrawal while already off writes nothing. A failed check is not
    // exhaustion, so it still advances the revision to stop in-flight grants.
    let coalesce = false;
    if (input?.aiSharing === false) {
      const limit = await checkRateLimit(db, `user:${auth.userId}:privacyConsent:withdraw`, STANDARD_USER_LIMIT, auth.userId);
      coalesce = !limit.allowed && !limit.failure;
    } else {
      const isRead = req.method === 'GET';
      const limit = await checkRateLimit(db, `user:${auth.userId}:privacyConsent:${isRead ? 'read' : 'grant'}`,
        isRead ? PRIVACY_CONSENT_READ_LIMIT : STANDARD_USER_LIMIT, auth.userId);
      if (!limit.allowed) return sendLimitCheckResponse(res, 'user', limit, {endpoint: 'privacyConsent'});
    }
    if (req.method === 'GET') return successResponse(res, parseConsent((await ref.get()).data()));
    if (!input) return errorResponse(res, 400, 'Invalid consent data');
    const result = await savePrivacyConsent(db, auth.userId, input, {coalesce});
    return successResponse(res, result);
  } catch (error) {
    if (error instanceof ConsentConflict) return errorResponse(res, 409, 'Consent changed; refresh and retry', undefined, 'CONSENT_CONFLICT');
    if (error instanceof AccountDeletingError) return errorResponse(res, 403, 'Account deletion is in progress', undefined, 'ACCOUNT_DELETING');
    logger.error('Privacy consent operation failed', safeErrorMetadata(error));
    return errorResponse(res, 503, 'Privacy settings unavailable; please retry');
  }
});
