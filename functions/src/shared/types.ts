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
 * - ageRange, gender, major, and occupation are SENSITIVE DATA (PII)
 * - Can identify users when combined with other profile fields (GDPR/CCPA concern)
 * - NEVER log these fields in plain text
 * - Validate incoming values against defined enums before storage
 * - Use redactSensitiveFields() when logging this data
 * - Consider field importance before including in AI prompts
 *
 * REQUIRED FIELDS: ageRange, gender, hobbies, optInTailored, translationPreference, timezone
 * OPTIONAL FIELDS: major, occupation (not everyone is in school or employed)
 */
export interface UserProfileInput {
  /** REQUIRED - SENSITIVE: Must be one of the predefined age ranges */
  ageRange: AgeRange;

  /** OPTIONAL - SENSITIVE: major/field of study (for students). May be free-form but should be validated. */
  major?: string;

  /** OPTIONAL - SENSITIVE: occupation/job title (for non-students). Can identify users when combined with other profile data. */
  occupation?: string;

  /** REQUIRED - SENSITIVE: Must be one of the predefined gender options */
  gender: Gender;

  /** REQUIRED - List of user hobbies/interests */
  hobbies: string[];

  /** REQUIRED - Whether user opts in to tailored encouragement */
  optInTailored: boolean;

  /** REQUIRED - Bible translation preference */
  translationPreference: 'ESV' | 'KJV' | 'NIV' | 'NKJV' | 'NASB' | 'CSB' | 'NLT';

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
 * SECURITY: Validates all fields including sensitive PII fields (ageRange, gender, major, occupation).
 * Sensitive fields should be treated as identifying information and protected accordingly.
 *
 * REQUIRED FIELDS: ageRange, gender, hobbies, optInTailored, translationPreference, timezone
 * OPTIONAL FIELDS: major, occupation
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

  // REQUIRED: Validate gender
  const gender = validateGender(obj.gender);
  if (!gender) {
    logger.error('Profile validation failed: missing or invalid gender');
    return undefined;
  }

  // REQUIRED: Validate translation preference
  let translationPref: UserProfileInput['translationPreference'] | undefined;
  if (obj.translationPreference !== undefined) {
    const validTranslations = ['ESV', 'KJV', 'NIV', 'NKJV', 'NASB', 'CSB', 'NLT'];
    const pref = String(obj.translationPreference).toUpperCase();
    if (validTranslations.includes(pref)) {
      translationPref = pref as UserProfileInput['translationPreference'];
    }
  }
  if (!translationPref) {
    logger.error('Profile validation failed: missing or invalid translationPreference');
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

  // REQUIRED: Validate hobbies (must be array, can be empty)
  let hobbies: string[];
  if (Array.isArray(obj.hobbies)) {
    hobbies = obj.hobbies.filter((h) => typeof h === 'string').slice(0, 10);
  } else {
    logger.error('Profile validation failed: missing or invalid hobbies');
    return undefined;
  }

  // OPTIONAL: Validate check-in times if provided
  let checkInTimes: CheckInTimes | undefined;
  if (obj.checkInTimes !== undefined) {
    checkInTimes = validateCheckInTimes(obj.checkInTimes);
  }

  return {
    ageRange,
    gender,
    hobbies,
    optInTailored: Boolean(obj.optInTailored),
    translationPreference: translationPref,
    timezone,
    // Optional fields
    major: typeof obj.major === 'string' ? obj.major.slice(0, 120) : undefined,
    occupation: typeof obj.occupation === 'string' ? obj.occupation.slice(0, 120) : undefined,
    checkInTimes,
  };
}

/**
 * Device registration input from client.
 *
 * SECURITY NOTES:
 * - notificationToken is SENSITIVE DATA (APNs/FCM device token)
 * - NEVER log notificationToken in plain text
 * - ALWAYS hash before storing in database
 * - Tokens should be validated before acceptance
 * - Implement token rotation (90-day retention policy)
 * - Delete tokens on app uninstall or user opt-out
 * - Ensure compliance with APNs/FCM policies
 * - Obtain user consent before storing tokens
 */
export interface DeviceRegistrationInput {
  deviceId: string;
  platform: 'ios' | 'android';
  appVersion?: string;
  /**
   * Push notification token (APNs for iOS, FCM for Android).
   *
   * SECURITY: This field contains sensitive device-specific data.
   * - Must be hashed using hashNotificationToken() before storage
   * - Must be redacted in logs using redactSensitiveFields()
   * - Must be validated using isValidNotificationToken()
   * - Must be deleted on uninstall/opt-out
   * - Subject to 90-day retention policy
   *
   * @see hashNotificationToken in shared/crypto.ts
   * @see registerDevice in shared/device.ts
   */
  notificationToken?: string;
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
  note?: string;              // optional free text
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
 * Bible translation options.
 */
export type Translation = 'ESV' | 'KJV' | 'NIV' | 'NKJV' | 'NASB' | 'CSB' | 'NLT';

/**
 * AI-generated encouragement response.
 */
export interface AIEncouragementResponse {
  message: string;        // Friend-like encouragement (2-3 sentences)
  verseRef: string;       // e.g., "Philippians 4:6-7"
  verseText: string;      // Full verse text
  translation: string;    // Bible translation used
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
  expiresAt: string;          // 24-hour TTL
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
const VALID_TRANSLATIONS: Translation[] = ['ESV', 'KJV', 'NIV', 'NKJV', 'NASB', 'CSB', 'NLT'];

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
    note: typeof obj.note === 'string' ? obj.note : undefined,
  };
}

/**
 * Validates translation preference.
 */
export function validateTranslation(value: unknown): Translation | undefined {
  if (typeof value !== 'string') return undefined;
  const upper = value.toUpperCase();
  return VALID_TRANSLATIONS.includes(upper as Translation) ? (upper as Translation) : undefined;
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
