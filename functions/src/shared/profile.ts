import { getFirestore } from 'firebase-admin/firestore';
import type { AgeRange, Gender, CheckInTimes, Translation } from './types';

export interface UserProfile {
  /** SENSITIVE: Stored PII - use redactSensitiveFields() when logging */
  ageRange?: AgeRange;

  /**
   * OPTIONAL - SENSITIVE: User's first name for Home-view greeting personalization.
   * NOT passed to AI agents — see profile-sanitize.ts::UserProfilePayload which
   * intentionally omits this field.
   */
  firstName?: string;

  /** SENSITIVE: Optional major/field of study (for students). Can identify users when combined with other profile data. */
  major?: string;

  /** SENSITIVE: Optional occupation/job title (for non-students). Can identify users when combined with other profile data. */
  occupation?: string;

  /** SENSITIVE: Stored PII - use redactSensitiveFields() when logging */
  gender?: Gender;

  hobbies?: string[];
  optInTailored?: boolean;
  translationPreference?: Translation;

  /** User's preferred check-in notification times */
  checkInTimes?: CheckInTimes;

  /** User's timezone for scheduling notifications (e.g., "America/New_York") */
  timezone?: string;

  updatedAt?: string;
}

/**
 * Fetch the user's profile document from Firestore.
 *
 * Historically this was backed by an in-process LRU cache to reduce Firestore
 * reads, but that cache introduced a privacy-sensitive consistency bug:
 * opt-out toggles (e.g., `optInTailored = false`) could take up to 10 minutes
 * to propagate because multiple Cloud Functions instances each held their own
 * TTL'd copy. At WalkWorthy's scale the savings are negligible (~5ms per call)
 * and not worth the coherence risk. Every call now round-trips to Firestore.
 */
export async function getUserProfileOnce(sub: string): Promise<UserProfile | undefined> {
  const db = getFirestore();
  const docRef = db.collection('users').doc(sub).collection('profile').doc('data');
  const docSnap = await docRef.get();
  return docSnap.exists ? (docSnap.data() as UserProfile) : undefined;
}

/**
 * Kept as a no-op for API compatibility with callers that used to invalidate
 * the cache on PUT/PATCH/DELETE. Now that `getUserProfileOnce` always reads
 * through, no invalidation is needed, but leaving the export in place avoids
 * forcing a large diff across api/user-profile.ts.
 */
export function clearUserProfileCache(_sub?: string): void {
  // Intentionally empty — no cache to clear.
}
