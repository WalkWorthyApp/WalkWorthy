import { logger } from 'firebase-functions/v2';
import { onRequest } from 'firebase-functions/v2/https';
import { FUNCTIONS_REVISION } from '../shared/version';
import { getDb, getAuthInstance, initializeFirebase } from '../shared/firebase';
import { verifyAppCheck, errorResponse, successResponse } from '../shared/auth';
import { PendingDeletionError, requestAccountDeletion } from '../shared/account-deletion';
import { sendRateLimitResponse } from '../shared/rate-limiter';

export { deleteAllUserFirestoreData } from '../shared/account-deletion';
initializeFirebase();

/** Resumable account erasure. Only an authenticated request creates a job. */
export const deleteAccount = onRequest({maxInstances: 10, timeoutSeconds: 540, invoker: 'public'}, async (req, res) => {
  logger.info('deleteAccount invoked', {revision: FUNCTIONS_REVISION});
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return errorResponse(res, 405, 'Method not allowed');
  }
  if (!await verifyAppCheck(req, res)) return;
  const token = req.headers.authorization?.match(/^Bearer (.+)$/)?.[1];
  if (!token) return errorResponse(res, 401, 'Authentication required');
  try {
    const result = await requestAccountDeletion(getDb(), getAuthInstance(), token);
    if (result.status === 'rate-limited') {
      return sendRateLimitResponse(res, 'user', result.retryAfterSeconds, {endpoint: 'deleteAccount'});
    }
    if (result.status === 'busy') {
      res.setHeader('Retry-After', '60');
      return errorResponse(res, 503, 'Account deletion is still running. Please retry shortly.');
    }
    return successResponse(res, {deleted: true});
  } catch (error) {
    const code = error && typeof error === 'object' ? (error as {code?: unknown}).code : undefined;
    if (typeof code === 'string' && ['auth/id-token-expired', 'auth/id-token-revoked', 'auth/argument-error', 'auth/invalid-id-token', 'auth/user-disabled', 'auth/user-not-found', 'auth/requires-recent-login'].includes(code)) {
      return errorResponse(res, 401, 'Sign in again to delete your account');
    }
    if (error instanceof PendingDeletionError) {
      logger.error('Accepted account deletion incomplete; pending job will be retried');
      return errorResponse(res, 503, 'Account deletion incomplete. Cleanup will be retried automatically; you can also retry or contact support.');
    }
    logger.error('Account deletion acceptance could not be confirmed');
    return errorResponse(res, 503, 'We could not confirm that your account deletion request was saved. Please retry or contact support.');
  }
});
