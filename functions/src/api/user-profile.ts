import { safeErrorMetadata } from '../shared/safe-logging';
import { FUNCTIONS_REVISION } from '../shared/version';
import { assertAccountActive, AccountDeletingError } from '../shared/account-lifecycle';
import { onRequest, HttpsOptions } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';
import { getDb, COLLECTIONS, initializeFirebase } from '../shared/firebase';
import { requireAuth, verifyAppCheck, errorResponse, successResponse } from '../shared/auth';
import { validateUserProfileInput, validateAgeRange, validateBirthDate, validateCheckInTimes, validateTimeZone } from '../shared/types';
import type { UserProfile } from '../shared/profile';
import { clearUserProfileCache } from '../shared/profile';
import { FieldValue } from 'firebase-admin/firestore';
import { checkRateLimit, sendLimitCheckResponse, STANDARD_USER_LIMIT } from '../shared/rate-limiter';

// Initialize Firebase on module load
initializeFirebase();

/**
 * Fields earlier builds stored but the app no longer collects. Any real
 * profile change deletes them: gender is no longer asked, translationPreference
 * is gone (ESV-only), optInTailored is retired (the profile is never sent to
 * AI), and major/occupation/hobbies are no longer collected.
 */
const RETIRED_PROFILE_FIELDS = [
  'gender', 'translationPreference', 'optInTailored', 'major', 'occupation', 'hobbies',
] as const;

const httpsOptions: HttpsOptions = {
  // CORS removed - not needed for mobile-only API (mobile apps don't enforce CORS)
  maxInstances: 10,
  invoker: 'public', // Allow unauthenticated HTTP access (auth handled in code)
};

/**
 * User Profile API
 *
 * GET /user-profile - Get current user's profile
 * PUT /user-profile - Create or update user's profile
 * PATCH /user-profile - Partially update user's profile
 * DELETE /user-profile - Delete user's profile
 */
export const userProfile = onRequest(httpsOptions, async (req, res) => {
  logger.info('userProfile invoked', { revision: FUNCTIONS_REVISION });
  // App Check verification
  const appCheckValid = await verifyAppCheck(req, res);
  if (!appCheckValid) return;

  const db = getDb();

  // Authenticate request
  const authReq = await requireAuth(req, res);
  if (!authReq) return;

  const { userId } = authReq;

  // User-based rate limiting
  const userRateResult = await checkRateLimit(db, `user:${userId}:userProfile`, STANDARD_USER_LIMIT, userId);
  if (!userRateResult.allowed) {
    sendLimitCheckResponse(res, 'user', userRateResult, { userId, endpoint: 'userProfile' });
    return;
  }
  const profileRef = db.collection(COLLECTIONS.users).doc(userId).collection('profile').doc('data');

  try {
    if (req.method !== 'GET' && req.method !== 'DELETE' && (!req.body || typeof req.body !== 'object' || Array.isArray(req.body))) return errorResponse(res, 400, 'Invalid profile data');
    switch (req.method) {
      case 'GET': {
        const doc = await profileRef.get();

        if (!doc.exists) {
          return successResponse(res, { profile: null });
        }

        const profile = doc.data() as UserProfile;
        logger.info('Profile retrieved');
        return successResponse(res, { profile });
      }

      case 'PUT': {
        // Full replace
        const validated = validateUserProfileInput(req.body);
        if (!validated) {
          return errorResponse(res, 400, 'Invalid profile data');
        }

        const profileData: UserProfile = {
          ageRange: validated.ageRange,
          firstName: validated.firstName,
          timezone: validated.timezone,
          checkInTimes: validated.checkInTimes,
          updatedAt: new Date().toISOString(),
        };

        await db.runTransaction(async tx => { await assertAccountActive(db, userId, tx); tx.set(profileRef, profileData); });
        clearUserProfileCache(userId);

        logger.info('Profile created/replaced');
        return successResponse(res, { profile: profileData }, 200);
      }

      case 'PATCH': {
        // Partial update
        const updates: Partial<UserProfile> = {};

        if (req.body.ageRange !== undefined) {
          const validAge = validateAgeRange(req.body.ageRange);
          if (req.body.ageRange === null || req.body.ageRange === '') {
            updates.ageRange = FieldValue.delete() as unknown as UserProfile['ageRange'];
          } else if (!validAge) {
            return errorResponse(res, 400, 'Invalid ageRange value');
          } else {
            updates.ageRange = validAge;
          }
        }

        if (req.body.birthDate !== undefined) {
          if (req.body.birthDate === null || req.body.birthDate === '') {
            updates.birthDate = FieldValue.delete() as unknown as string | undefined;
          } else {
            const validBirthDate = validateBirthDate(req.body.birthDate);
            if (!validBirthDate) {
              return errorResponse(res, 400, 'Invalid birthDate value');
            }
            updates.birthDate = validBirthDate;
            // The birth date supersedes the legacy age bucket; keep one source.
            updates.ageRange = FieldValue.delete() as unknown as UserProfile['ageRange'];
          }
        }

        if (req.body.firstName !== undefined) {
          if (req.body.firstName === null) {
            updates.firstName = FieldValue.delete() as unknown as string | undefined;
          } else if (typeof req.body.firstName === 'string') {
            const trimmed = req.body.firstName.trim();
            if (trimmed.length === 0) {
              // Empty string clears the field (client convenience: some UIs can't send null)
              updates.firstName = FieldValue.delete() as unknown as string | undefined;
            } else if (trimmed.length <= 60) {
              updates.firstName = trimmed;
            } else {
              return errorResponse(res, 400, 'Invalid firstName value');
            }
          } else {
            return errorResponse(res, 400, 'Invalid firstName value');
          }
        }

        if (req.body.timezone !== undefined) {
          const validTimeZone = validateTimeZone(req.body.timezone);
          if (validTimeZone) {
            updates.timezone = validTimeZone;
          } else {
            return errorResponse(res, 400, 'Invalid timezone value');
          }
        }

        if (req.body.checkInTimes !== undefined) {
          const validCheckInTimes = validateCheckInTimes(req.body.checkInTimes);
          if (req.body.checkInTimes !== null && !validCheckInTimes) {
            return errorResponse(res, 400, 'Invalid checkInTimes value');
          }
          updates.checkInTimes = validCheckInTimes;
        }

        // Reject a request that carried no recognized field BEFORE adding the
        // server-owned fields below — otherwise this guard can never fire.
        if (Object.keys(updates).length === 0) {
          return errorResponse(res, 400, 'No valid fields to update');
        }

        for (const field of RETIRED_PROFILE_FIELDS) {
          (updates as Record<string, unknown>)[field] = FieldValue.delete();
        }
        updates.updatedAt = new Date().toISOString();

        // Atomically create or update the document using merge
        // This avoids race conditions between checking existence and updating
        await db.runTransaction(async tx => { await assertAccountActive(db, userId, tx); tx.set(profileRef, updates, { merge: true }); });

        clearUserProfileCache(userId);

        logger.info('Profile updated');

        // Return updated profile
        const updatedDoc = await profileRef.get();
        return successResponse(res, { profile: updatedDoc.data() });
      }

      case 'DELETE': {
        await db.runTransaction(async tx => { await assertAccountActive(db, userId, tx); tx.delete(profileRef); });
        clearUserProfileCache(userId);

        logger.info('Profile deleted');
        return successResponse(res, { deleted: true });
      }

      default:
        res.setHeader('Allow', 'GET, PUT, PATCH, DELETE');
        return errorResponse(res, 405, `Method ${req.method} not allowed`);
    }
  } catch (error) {
    if (error instanceof AccountDeletingError) return errorResponse(res, 403, 'Account deletion in progress', undefined, 'ACCOUNT_DELETING');
    logger.error('Profile operation failed', safeErrorMetadata(error));
    return errorResponse(res, 500, 'Internal server error');
  }
});
