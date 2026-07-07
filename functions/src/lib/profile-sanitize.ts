/**
 * Shared profile + text sanitization helpers used by AI agents.
 *
 * Extracted from mood-agent.ts so the reflection agent can use the same
 * sanitization logic without duplication. Preserves existing behavior:
 *   - Text fields capped at 120 chars (major/occupation) or 40 chars (hobbies)
 *   - Hobbies list capped at 6 entries
 *   - Strips HTML tags and URLs
 *   - Validates gender/ageRange via shared type validators
 */

import type { AgeRange, Gender } from "../shared/types";
import { validateAgeRange, validateGender } from "../shared/types";

/**
 * Profile payload shape as consumed by AI agents. Mirrors a subset of
 * shared/profile.ts::UserProfile but includes only fields the AI should see.
 */
export interface UserProfilePayload {
  /** SENSITIVE: Optional major/field of study (for students). Can identify users when combined with other profile data. */
  major?: string;
  /** SENSITIVE: Optional occupation/job title (for non-students). Can identify users when combined with other profile data. */
  occupation?: string;
  /** SENSITIVE: Gender is PII; must be one of the predefined gender options */
  gender?: Gender;
  /** SENSITIVE: Age range is PII; must be one of the predefined ranges */
  ageRange?: AgeRange;
  hobbies?: string[];
  optInTailored?: boolean;
}

/**
 * General-purpose text sanitizer: strips HTML tags and URLs, collapses
 * whitespace, and truncates to `max` characters.
 */
export function sanitizeText(text: string, max = 400): string {
  const stripped = text
    .replace(/<[^>]+>/g, " ")
    .replace(/https?:\/\/\S+/gi, " ");
  return stripped.replace(/\s+/g, " ").trim().slice(0, max);
}

/**
 * Preset hobby vocabulary from the iOS onboarding picker (Hobby enum in
 * EncouragementModels.swift). These are generic devotional/lifestyle words —
 * "worship" or "serving" legitimately appear in Scripture-based encouragement
 * prose, so echo-checking them would cause routine false-positive guardrail
 * trips. Only user-TYPED custom hobbies (which can be arbitrarily specific
 * and identifying) are echo-checked.
 */
const PRESET_HOBBIES: ReadonlySet<string> = new Set([
  'worship', 'serving', 'music', 'athletics',
  'art', 'reading', 'mentoring', 'outdoors',
]);

/**
 * Collect the profile strings that get sent to the AI agents, for use with
 * assertNoProfileEcho(). Operates on the SANITIZED profile so the checked
 * values are exactly what the model saw. firstName is never sent to agents,
 * so it is not collected here; preset hobby words are excluded (see above).
 */
export function collectProfileValues(
  profile: UserProfilePayload | null,
): string[] {
  if (!profile) return [];
  const customHobbies = (profile.hobbies ?? []).filter(
    (h) => typeof h === 'string' && !PRESET_HOBBIES.has(h.trim().toLowerCase()),
  );
  return [
    profile.major,
    profile.occupation,
    profile.gender,
    profile.ageRange,
    ...customHobbies,
  ].filter((v): v is string => typeof v === "string" && v.trim().length > 0);
}

/**
 * Sanitize a user profile for safe inclusion in AI agent input.
 *
 * Validates sensitive enum fields (gender, ageRange) and caps free-form
 * text fields. Returns null when the profile is null/undefined.
 */
export function sanitizeProfile(
  profile: UserProfilePayload | null | undefined,
): UserProfilePayload | null {
  if (!profile) return null;

  // Validate sensitive enum fields to prevent invalid data being passed to AI
  const validGender = profile.gender
    ? validateGender(profile.gender)
    : undefined;
  const validAgeRange = profile.ageRange
    ? validateAgeRange(profile.ageRange)
    : undefined;

  return {
    major: profile.major ? sanitizeText(profile.major, 120) : undefined,
    occupation: profile.occupation
      ? sanitizeText(profile.occupation, 120)
      : undefined,
    gender: validGender,
    ageRange: validAgeRange,
    hobbies: profile.hobbies?.slice(0, 6).map((h) => sanitizeText(h, 40)),
    optInTailored: Boolean(profile.optInTailored),
  };
}
