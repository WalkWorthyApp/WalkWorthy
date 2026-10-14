import { logger } from 'firebase-functions/v2';
import { onRequest } from 'firebase-functions/v2/https';
import { FUNCTIONS_REVISION } from '../shared/version';
import { checkRateLimit, sendLimitCheckResponse } from '../shared/rate-limiter';
import type { RateLimitConfig } from '../shared/rate-limiter';
import { getDb, initializeFirebase } from '../shared/firebase';
import { requireAuth, verifyAppCheck, errorResponse, successResponse } from '../shared/auth';
import { AccountDeletingError } from '../shared/account-lifecycle';
import { safeErrorMetadata } from '../shared/safe-logging';
import { validateSuggestionInput, saveSuggestion } from '../shared/suggestion';
initializeFirebase();

export const SUGGESTION_USER_LIMIT: RateLimitConfig = { maxRequests: 5, windowMs: 24 * 60 * 60 * 1000 };

/** Suggestion box: POST stores one user-written suggestion for the developer to read. */
export const suggestion = onRequest({ maxInstances: 10, timeoutSeconds: 30, invoker: 'public' }, async (req, res) => {
  logger.info('suggestion invoked', { revision: FUNCTIONS_REVISION });
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return errorResponse(res, 405, 'Method not allowed');
  }
  if (!await verifyAppCheck(req, res)) return;
  const auth = await requireAuth(req, res);
  if (!auth) return;
  const input = validateSuggestionInput(req.body);
  if (!input) return errorResponse(res, 400, 'Invalid suggestion');
  const db = getDb();
  try {
    const limit = await checkRateLimit(db, `user:${auth.userId}:suggestion`, SUGGESTION_USER_LIMIT, auth.userId);
    if (!limit.allowed) return sendLimitCheckResponse(res, 'user', limit, { endpoint: 'suggestion' });
    const { created } = await saveSuggestion(db, auth.userId, input);
    // The text is user-written and may be sensitive; never log it.
    logger.info('Suggestion stored', { category: input.category, length: [...input.text].length, created });
    return successResponse(res, { id: input.id }, created ? 201 : 200);
  } catch (error) {
    if (error instanceof AccountDeletingError) return errorResponse(res, 403, 'Account deletion is in progress', undefined, 'ACCOUNT_DELETING');
    logger.error('Suggestion save failed', safeErrorMetadata(error));
    return errorResponse(res, 503, 'Suggestions unavailable; please retry');
  }
});
