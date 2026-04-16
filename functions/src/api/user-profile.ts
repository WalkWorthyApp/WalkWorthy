import { onRequest, HttpsOptions } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';
import { getDb, COLLECTIONS, initializeFirebase } from '../shared/firebase';
import { requireAuth, verifyAppCheck, errorResponse, successResponse } from '../shared/auth';
import { validateUserProfileInput, validateAgeRange, validateGender, validateCheckInTimes } from '../shared/types';
import type { UserProfile } from '../shared/profile';
import { clearUserProfileCache } from '../shared/profile';
import { FieldValue } from 'firebase-admin/firestore';
import { checkRateLimit, getClientIp, STANDARD_USER_LIMIT, STANDARD_IP_LIMIT } from '../shared/rate-limiter';

// Initialize Firebase on module load
initializeFirebase();

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
  // App Check verification
  const appCheckValid = await verifyAppCheck(req, res);
  if (!appCheckValid) return;

  // IP-based rate limiting
  const db = getDb();
  const clientIp = getClientIp(req);
  const ipResult = await checkRateLimit(db, `ip:${clientIp}:userProfile`, STANDARD_IP_LIMIT);
  if (!ipResult.allowed) {
    res.set('Retry-After', String(ipResult.retryAfterSeconds));
    return errorResponse(res, 429, 'Too many requests. Please try again later.');
  }

  // Authenticate request
  const authReq = await requireAuth(req, res);
  if (!authReq) return;

  const { userId } = authReq;

  // User-based rate limiting
  const userRateResult = await checkRateLimit(db, `user:${userId}:userProfile`, STANDARD_USER_LIMIT);
  if (!userRateResult.allowed) {
    res.set('Retry-After', String(userRateResult.retryAfterSeconds));
    return errorResponse(res, 429, 'Too many requests. Please try again later.');
  }
  const profileRef = db.collection(COLLECTIONS.users).doc(userId).collection('profile').doc('data');

  try {
    switch (req.method) {
      case 'GET': {
        const doc = await profileRef.get();

        if (!doc.exists) {
          return successResponse(res, { profile: null });
        }

        const profile = doc.data() as UserProfile;
        logger.info('Profile retrieved', { userId });
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
          gender: validated.gender,
          major: validated.major,
          occupation: validated.occupation,
          hobbies: validated.hobbies,
          optInTailored: validated.optInTailored,
          translationPreference: validated.translationPreference,
          timezone: validated.timezone,
          checkInTimes: validated.checkInTimes,
          updatedAt: new Date().toISOString(),
        };

        await profileRef.set(profileData);
        clearUserProfileCache(userId);

        logger.info('Profile created/replaced', { userId });
        return successResponse(res, { profile: profileData }, 200);
      }

      case 'PATCH': {
        // Partial update
        const updates: Partial<UserProfile> = {};

        if (req.body.ageRange !== undefined) {
          const validAge = validateAgeRange(req.body.ageRange);
          if (req.body.ageRange !== null && !validAge) {
            return errorResponse(res, 400, 'Invalid ageRange value');
          }
          updates.ageRange = validAge;
        }

        if (req.body.gender !== undefined) {
          const validGender = validateGender(req.body.gender);
          if (req.body.gender !== null && !validGender) {
            return errorResponse(res, 400, 'Invalid gender value');
          }
          updates.gender = validGender;
        }

        if (req.body.major !== undefined) {
          if (req.body.major === null) {
            updates.major = FieldValue.delete() as unknown as string | undefined;
          } else if (typeof req.body.major === 'string') {
            const trimmed = req.body.major.trim();
            if (trimmed.length > 0 && trimmed.length <= 120) {
              updates.major = trimmed;
            } else {
              return errorResponse(res, 400, 'Invalid major value');
            }
          } else {
            return errorResponse(res, 400, 'Invalid major value');
          }
        }

        if (req.body.occupation !== undefined) {
          if (req.body.occupation === null) {
            updates.occupation = FieldValue.delete() as unknown as string | undefined;
          } else if (typeof req.body.occupation === 'string') {
            const trimmed = req.body.occupation.trim();
            if (trimmed.length > 0 && trimmed.length <= 120) {
              updates.occupation = trimmed;
            } else {
              return errorResponse(res, 400, 'Invalid occupation value');
            }
          } else {
            return errorResponse(res, 400, 'Invalid occupation value');
          }
        }

        if (req.body.hobbies !== undefined) {
          if (Array.isArray(req.body.hobbies)) {
            const filtered = req.body.hobbies
              .filter((h: unknown) => typeof h === 'string')
              .map((h: string) => h.trim())
              .filter((h: string) => h.length > 0 && h.length <= 120)
              .slice(0, 10);
            updates.hobbies = filtered.length > 0 ? filtered : FieldValue.delete() as unknown as string[] | undefined;
          } else if (req.body.hobbies === null) {
            updates.hobbies = FieldValue.delete() as unknown as string[] | undefined;
          } else {
            return errorResponse(res, 400, 'Invalid hobbies value');
          }
        }

        if (req.body.optInTailored !== undefined) {
          updates.optInTailored = Boolean(req.body.optInTailored);
        }

        if (req.body.translationPreference !== undefined) {
          const validTranslations = ['ESV', 'KJV', 'NIV', 'NKJV', 'NASB', 'CSB', 'NLT'];
          const pref = String(req.body.translationPreference).toUpperCase();
          if (!validTranslations.includes(pref)) {
            return errorResponse(res, 400, 'Invalid translationPreference value');
          }
          updates.translationPreference = pref as UserProfile['translationPreference'];
        }

        if (req.body.timezone !== undefined) {
          if (typeof req.body.timezone === 'string' && req.body.timezone.length > 0 && req.body.timezone.length <= 50) {
            updates.timezone = req.body.timezone;
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

        if (Object.keys(updates).length === 0) {
          return errorResponse(res, 400, 'No valid fields to update');
        }

        updates.updatedAt = new Date().toISOString();

        // Atomically create or update the document using merge
        // This avoids race conditions between checking existence and updating
        await profileRef.set(updates, { merge: true });

        clearUserProfileCache(userId);

        logger.info('Profile updated', { userId, fields: Object.keys(updates) });

        // Return updated profile
        const updatedDoc = await profileRef.get();
        return successResponse(res, { profile: updatedDoc.data() });
      }

      case 'DELETE': {
        await profileRef.delete();
        clearUserProfileCache(userId);

        logger.info('Profile deleted', { userId });
        return successResponse(res, { deleted: true });
      }

      default:
        res.setHeader('Allow', 'GET, PUT, PATCH, DELETE');
        return errorResponse(res, 405, `Method ${req.method} not allowed`);
    }
  } catch (error) {
    logger.error('Profile operation failed', {
      userId,
      method: req.method,
      error: error instanceof Error ? error.message : 'Unknown error',
    });
    return errorResponse(res, 500, 'Internal server error');
  }
});
