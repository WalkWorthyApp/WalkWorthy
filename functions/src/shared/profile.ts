import { getFirestore } from 'firebase-admin/firestore';
import type { AgeRange, Gender, CheckInTimes } from './types';

export interface UserProfile {
  /**
   * LEGACY - SENSITIVE: age bucket stored before birth dates were collected.
   * Deleted when a birth date is saved.
   */
  ageRange?: AgeRange;

  /**
   * SENSITIVE: "YYYY-MM-DD", validated 18+. Used only by the app to confirm the
   * age minimum and for the on-device birthday greeting. Never logged and
   * never sent to AI agents.
   */
  birthDate?: string;

  /** OPTIONAL - SENSITIVE: First name for the app's greeting and on-device birthday notification. */
  firstName?: string;

  /** SENSITIVE: Stored PII - use redactSensitiveFields() when logging */
  gender?: Gender;

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
 * profile edits (then including the AI-personalization opt-out) could take up to 10 minutes
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
