import { logger } from "firebase-functions/v2";

/**
 * Age ranges for user demographic profiling.
 * SENSITIVE: This field is PII; never log or expose unnecessarily.
 */
export type AgeRange = '18-24' | '25-34' | '35-44' | '45-54' | '55-64' | '65+';

/**
 * Gender identity options for user profiling.
 * SENSITIVE: This field is PII; never log or expose unnecessarily.
 */
export type Gender = 'female' | 'male' | 'nonBinary' | 'preferNotToSay';

/**
 * User profile input from client.
 *
 * SECURITY NOTES:
 * - ageRange and firstName are SENSITIVE DATA (PII)
 * - Can identify users when combined with other profile fields (GDPR/CCPA concern)
 * - NEVER log these fields in plain text
 * - Validate incoming values against defined enums before storage
 * - Use redactSensitiveFields() when logging this data
 * - Never include these fields in AI prompts
 *
 * REQUIRED FIELDS: ageRange, timezone
 * OPTIONAL FIELDS: firstName, checkInTimes
 */
export interface UserProfileInput {
  /** REQUIRED - SENSITIVE: Must be one of the predefined age ranges */
  ageRange: AgeRange;

  /**
   * OPTIONAL - SENSITIVE: First name for the app's greeting and on-device birthday notification.
   * NOT passed to AI agents. Validated: trimmed, 1–60 chars.
   */
  firstName?: string;

  /** OPTIONAL - User's preferred check-in notification times */
  checkInTimes?: CheckInTimes;

  /** REQUIRED - User's timezone for scheduling notifications */
  timezone: string;
}

/**
 * Validates and normalizes age range input from user.
 * SECURITY: Always validate user input before storage to prevent PII corruption.
 *
 * @param value The untrusted age range value from client
 * @returns The validated AgeRange or undefined if invalid
 */
export function validateAgeRange(value: unknown): AgeRange | undefined {
  if (typeof value !== 'string') return undefined;
  const validRanges: AgeRange[] = ['18-24', '25-34', '35-44', '45-54', '55-64', '65+'];
  return validRanges.includes(value as AgeRange) ? (value as AgeRange) : undefined;
}

/** WalkWorthy is adults-only; mirrors `OnboardingForm.minimumAge` on iOS. */
export const MINIMUM_AGE = 18;

/** Hours behind UTC of the last time zone to reach a new day (UTC-12). */
const LATEST_UTC_OFFSET_HOURS = 12;

/**
 * Validates a birth date: a real Gregorian "YYYY-MM-DD" day from 1900 on, for
 * someone at least MINIMUM_AGE. Age is counted on the earliest calendar day
 * still current anywhere on Earth (UTC-12), so a minor's birth date is never
 * stored; someone whose 18th birthday has only just begun may be refused for
 * up to a day.
 * SENSITIVE: never log the value.
 *
 * @param value The untrusted birth date from the client
 * @param now Current time (injectable for tests)
 * @returns The validated birth date or undefined if invalid or under age
 */
export function validateBirthDate(value: unknown, now: Date = new Date()): string | undefined {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return undefined;
  const year = Number(value.slice(0, 4));
  const month = Number(value.slice(5, 7));
  const day = Number(value.slice(8, 10));
  const date = new Date(Date.UTC(year, month - 1, day));
  if (year < 1900 || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return undefined;

  const earliest = new Date(now.getTime() - LATEST_UTC_OFFSET_HOURS * 60 * 60 * 1000);
  const earliestMonth = earliest.getUTCMonth() + 1;
  const hadBirthday = earliestMonth > month || (earliestMonth === month && earliest.getUTCDate() >= day);
  const age = earliest.getUTCFullYear() - year - (hadBirthday ? 0 : 1);
  return age >= MINIMUM_AGE ? value : undefined;
}

/**
 * Validates and normalizes gender input from user.
 * SECURITY: Always validate user input before storage to prevent PII corruption.
 *
 * @param value The untrusted gender value from client
 * @returns The validated Gender or undefined if invalid
 */
export function validateGender(value: unknown): Gender | undefined {
  if (typeof value !== 'string') return undefined;
  const validGenders: Gender[] = ['female', 'male', 'nonBinary', 'preferNotToSay'];
  return validGenders.includes(value as Gender) ? (value as Gender) : undefined;
}

/**
 * Validates and normalizes user profile input.
 * SECURITY: Validates all fields including sensitive PII fields (ageRange, firstName).
 * Sensitive fields should be treated as identifying information and protected accordingly.
 *
 * REQUIRED FIELDS: ageRange, timezone
 * OPTIONAL FIELDS: firstName, checkInTimes
 *
 * @param input The untrusted profile input from client
 * @returns Validated and sanitized UserProfileInput or undefined if required fields are missing/invalid
 */
export function validateUserProfileInput(input: unknown): UserProfileInput | undefined {
  if (!input || typeof input !== 'object') return undefined;

  const obj = input as Record<string, unknown>;

  // REQUIRED: Validate ageRange
  const ageRange = validateAgeRange(obj.ageRange);
  if (!ageRange) {
    logger.error('Profile validation failed: missing or invalid ageRange');
    return undefined;
  }

  // REQUIRED: Validate timezone (basic IANA timezone format check)
  let timezone: string | undefined;
  if (typeof obj.timezone === 'string' && obj.timezone.length > 0 && obj.timezone.length <= 50) {
    timezone = obj.timezone;
  }
  if (!timezone) {
    logger.error('Profile validation failed: missing or invalid timezone');
    return undefined;
  }

  // OPTIONAL: Validate check-in times if provided
  let checkInTimes: CheckInTimes | undefined;
  if (obj.checkInTimes !== undefined) {
    checkInTimes = validateCheckInTimes(obj.checkInTimes);
  }

  // OPTIONAL: Validate firstName (trim + length 1–60 when present)
  let firstName: string | undefined;
  if (typeof obj.firstName === 'string') {
    const trimmed = obj.firstName.trim();
    if (trimmed.length > 0 && trimmed.length <= 60) {
      firstName = trimmed;
    }
  }

  return {
    ageRange,
    timezone,
    // Optional fields
    firstName,
    checkInTimes,
  };
}

export interface EncouragementPayload {
  id: string;
  ref: string;
  text: string;
  encouragement: string;
  translation?: string;
  expiresAtIso: string;
}

// ============================================================================
// Mood Tracking Types
// ============================================================================

/**
 * Check-in type indicating time of day.
 */
export type CheckInType = 'morning' | 'midday' | 'evening';

/**
 * Mood level derived from moodScore on the spectrum slider.
 */
export type MoodLevel = 'very_unpleasant' | 'unpleasant' | 'neutral' | 'pleasant' | 'very_pleasant';

/**
 * Mood spectrum data collected during a check-in.
 */
export interface MoodSpectrumData {
  moodScore: number;          // 1–10, mapped from slider
  moodLevel: MoodLevel;       // derived from moodScore
  emotionTags: string[];      // selected emotion words (multi-select)
  impactCategories: string[]; // selected life impact areas (multi-select)
  followUpScore: number;      // 1–4 numeric from follow-up question
  note: string | null;        // optional free text; null when not provided
}

/**
 * A standalone journal entry optionally linked to a check-in.
 */
export interface JournalEntry {
  id: string;
  text: string;
  date: string;               // YYYY-MM-DD
  linkedCheckInId?: string;   // optional link to check-in
  createdAt: string;          // ISO 8601
  updatedAt: string;          // ISO 8601
}

/**
 * An optional help resource surfaced ALONGSIDE an encouragement — never in
 * place of one. Attached when a check-in note is classified as a self-harm
 * signal, so the user still receives their encouragement and is separately
 * offered a way to reach a person. The app renders this as its own card; it
 * never dials or contacts anyone automatically.
 */
export interface SupportResource {
  title: string;          // Short card heading
  body: string;           // One or two sentences of context
  phone?: string;         // Dialable/textable short code, e.g. "988"
  url?: string;           // Web fallback, e.g. https://988lifeline.org
}

/**
 * AI-generated encouragement response.
 */
export interface AIEncouragementResponse {
  message: string;        // Friend-like encouragement (2-3 sentences)
  verseRef: string;       // e.g., "Philippians 4:6-7"
  verseText: string;      // Full verse text
  translation: string;    // Bible translation used
  /** Optional; present only on the deterministic crisis-signal path. */
  supportResource?: SupportResource;
  /**
   * False on the fixed, human-written fallbacks (crisis signal, blocked input,
   * blocked output). Absent means model-generated — every record written
   * before this field existed was, so absent must read as true.
   *
   * The app keys three things off this: the "AI-generated" badge, the
   * "can get things wrong" caveat, and the retry control. All three are wrong
   * on a fixed response — retry re-runs and returns the identical string, and
   * telling someone an emergency-resource message is AI-written and may be
   * mistaken undermines it exactly when it needs to be trusted.
   */
  isGenerated?: boolean;
}

/**
 * Complete mood check-in record stored in Firestore.
 */
export interface MoodCheckIn {
  id: string;
  checkInType: CheckInType;
  timestamp: string;          // ISO 8601
  date: string;               // YYYY-MM-DD for easy querying
  moodSpectrumData: MoodSpectrumData;
  aiResponse: AIEncouragementResponse;
  createdAt: string;          // ISO 8601
  expiresAt: string;          // Client display metadata; retained until account deletion.
}

/**
 * Summary of a single check-in for daily aggregation.
 */
export interface CheckInSummary {
  checkInId: string;
  moodLevel: MoodLevel;
  respondedAt: string;    // ISO 8601
}

/**
 * Daily mood summary aggregating all check-ins for a day.
 */
export interface DailyMoodSummary {
  date: string;           // YYYY-MM-DD
  morning?: CheckInSummary | null;
  midday?: CheckInSummary | null;
  evening?: CheckInSummary | null;
  overallSentiment?: 'positive' | 'neutral' | 'challenging' | null;
  updatedAt: string;      // ISO 8601
}

/**
 * Input for submitting a mood check-in.
 */
export interface MoodCheckInInput {
  checkInType: CheckInType;
  moodSpectrumData: MoodSpectrumData;
}

/**
 * Response from mood check-in submission.
 */
export interface MoodCheckInResponse {
  checkInId: string;
  aiResponse: AIEncouragementResponse;
  createdAt: string;
  expiresAt: string;
}

/**
 * Pending check-in information.
 */
export interface PendingCheckIn {
  checkInType: CheckInType;
  dueAt: string;          // ISO 8601
  isOverdue: boolean;
}

/**
 * User's preferred check-in times.
 */
export interface CheckInTimes {
  morning: string;        // "07:30" HH:mm format
  midday: string;         // "12:00"
  evening: string;        // "20:00"
}

// ============================================================================
// Validation Functions for Mood Types
// ============================================================================

const VALID_CHECK_IN_TYPES: CheckInType[] = ['morning', 'midday', 'evening'];

// All valid emotion tags across all mood levels
const VALID_EMOTION_TAGS: ReadonlySet<string> = new Set([
  // Very Unpleasant
  'Angry', 'Anxious', 'Scared', 'Overwhelmed', 'Ashamed', 'Disgusted', 'Embarrassed',
  'Frustrated', 'Annoyed', 'Jealous', 'Stressed', 'Worried', 'Guilty', 'Hopeless',
  'Irritated', 'Lonely', 'Discouraged', 'Disappointed', 'Drained', 'Sad',
  // Unpleasant / Neutral / Pleasant / Very Pleasant
  'Tired', 'Uncertain', 'Indifferent', 'Steady', 'Okay',
  'Content', 'Calm', 'Peaceful', 'Hopeful', 'Grateful', 'Confident', 'Relieved',
  'Encouraged', 'Joyful', 'Satisfied',
  'Amazed', 'Excited', 'Blessed', 'Faithful', 'Proud', 'Thankful', 'Inspired', 'Energized',
]);

const VALID_IMPACT_CATEGORIES: ReadonlySet<string> = new Set([
  // Faith
  'Faith', 'Scripture', 'Prayer', 'Church', 'Community',
  // Personal
  'Health', 'Self-Care', 'Hobbies', 'Identity', 'Fitness',
  // Relationships
  'Family', 'Friends', 'Dating', 'Partner',
  // School/Work
  'Education', 'Tasks', 'Work', 'Money',
  // External
  'Weather', 'Current Events', 'Travel',
]);

/**
 * Derives the MoodLevel from a validated moodScore (1–10).
 */
function moodLevelFromScore(score: number): MoodLevel {
  if (score <= 2) return 'very_unpleasant';
  if (score <= 4) return 'unpleasant';
  if (score <= 6) return 'neutral';
  if (score <= 8) return 'pleasant';
  return 'very_pleasant';
}

/**
 * Validates check-in type.
 */
export function validateCheckInType(value: unknown): CheckInType | undefined {
  if (typeof value !== 'string') return undefined;
  return VALID_CHECK_IN_TYPES.includes(value as CheckInType) ? (value as CheckInType) : undefined;
}

/**
 * Validates mood spectrum data from client input.
 */
export function validateMoodSpectrumData(input: unknown): MoodSpectrumData | undefined {
  if (!input || typeof input !== 'object') return undefined;

  const obj = input as Record<string, unknown>;

  // validate moodScore (integer 1-10)
  if (typeof obj.moodScore !== 'number' || !Number.isInteger(obj.moodScore) || obj.moodScore < 1 || obj.moodScore > 10) {
    return undefined;
  }
  // derive moodLevel server-side — never trust client value
  const moodLevel = moodLevelFromScore(obj.moodScore);

  // validate emotionTags (array of strings); filter to allowlist, max 5 items
  if (!Array.isArray(obj.emotionTags)) return undefined;
  const rawTags = obj.emotionTags.filter((tag): tag is string => typeof tag === 'string');
  const emotionTags = rawTags.filter((t) => VALID_EMOTION_TAGS.has(t)).slice(0, 5);

  // validate impactCategories (array of strings); filter to allowlist, max 5 items
  if (!Array.isArray(obj.impactCategories)) return undefined;
  const rawCategories = obj.impactCategories.filter((cat): cat is string => typeof cat === 'string');
  const impactCategories = rawCategories.filter((c) => VALID_IMPACT_CATEGORIES.has(c)).slice(0, 5);

  // validate followUpScore (integer 1-4)
  if (typeof obj.followUpScore !== 'number' || !Number.isInteger(obj.followUpScore) || obj.followUpScore < 1 || obj.followUpScore > 4) {
    return undefined;
  }

  // note is optional string, max 500 chars
  if (obj.note !== undefined && (typeof obj.note !== 'string' || obj.note.length > 500)) {
    return undefined;
  }

  return {
    moodScore: obj.moodScore,
    moodLevel,
    emotionTags,
    impactCategories,
    followUpScore: obj.followUpScore,
    note: typeof obj.note === 'string' ? obj.note : null,
  };
}

/**
 * Validates check-in times format (HH:mm).
 */
export function validateCheckInTimes(times: unknown): CheckInTimes | undefined {
  if (!times || typeof times !== 'object') return undefined;

  const obj = times as Record<string, unknown>;
  const timeRegex = /^([01]\d|2[0-3]):([0-5]\d)$/;

  if (typeof obj.morning !== 'string' || !timeRegex.test(obj.morning)) return undefined;
  if (typeof obj.midday !== 'string' || !timeRegex.test(obj.midday)) return undefined;
  if (typeof obj.evening !== 'string' || !timeRegex.test(obj.evening)) return undefined;

  return {
    morning: obj.morning,
    midday: obj.midday,
    evening: obj.evening,
  };
}
