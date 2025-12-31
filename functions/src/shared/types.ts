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
    console.error('Profile validation failed: missing or invalid ageRange');
    return undefined;
  }

  // REQUIRED: Validate gender
  const gender = validateGender(obj.gender);
  if (!gender) {
    console.error('Profile validation failed: missing or invalid gender');
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
    console.error('Profile validation failed: missing or invalid translationPreference');
    return undefined;
  }

  // REQUIRED: Validate timezone (basic IANA timezone format check)
  let timezone: string | undefined;
  if (typeof obj.timezone === 'string' && obj.timezone.length > 0 && obj.timezone.length <= 50) {
    timezone = obj.timezone;
  }
  if (!timezone) {
    console.error('Profile validation failed: missing or invalid timezone');
    return undefined;
  }

  // REQUIRED: Validate hobbies (must be array, can be empty)
  let hobbies: string[];
  if (Array.isArray(obj.hobbies)) {
    hobbies = obj.hobbies.filter((h) => typeof h === 'string').slice(0, 10);
  } else {
    console.error('Profile validation failed: missing or invalid hobbies');
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
 * Morning mood options - how user feels about their upcoming day.
 */
export type MorningMood = 'hopeful' | 'anxious' | 'tired' | 'confident' | 'nervous' | 'uncertain';

/**
 * Midday mood options - how the day is going so far.
 */
export type MiddayMood = 'better than expected' | 'as expected' | 'harder than expected' | 'stressful';

/**
 * Evening mood options - how the day went.
 */
export type EveningMood = 'great day' | 'good day' | 'challenging day' | 'difficult day';

/**
 * All possible mood values across check-in types.
 */
export type MoodOption = MorningMood | MiddayMood | EveningMood;

/**
 * Morning follow-up options - workload for the day.
 */
export type MorningFollowUp = 'yes' | 'no' | 'somewhat';

/**
 * Midday follow-up options - what would help most.
 */
export type MiddayFollowUp = 'encouragement' | 'peace' | 'strength' | 'wisdom';

/**
 * Evening follow-up options - feelings about tomorrow.
 */
export type EveningFollowUp = 'hopeful' | 'nervous' | 'uncertain' | 'ready';

/**
 * Bible translation options.
 */
export type Translation = 'ESV' | 'KJV' | 'NIV' | 'NKJV' | 'NASB' | 'CSB' | 'NLT';

/**
 * User's mood responses for a check-in.
 */
export interface MoodResponses {
  primaryMood: string;
  followUpResponse: string;
}

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
  timestamp: string;       // ISO 8601
  date: string;           // YYYY-MM-DD for easy querying
  responses: MoodResponses;
  aiResponse: AIEncouragementResponse;
  createdAt: string;      // ISO 8601
  expiresAt: string;      // 24-hour TTL
}

/**
 * Summary of a single check-in for daily aggregation.
 */
export interface CheckInSummary {
  checkInId: string;
  primaryMood: string;
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
  primaryMood: string;
  followUpResponse: string;
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
const VALID_MORNING_MOODS: MorningMood[] = ['hopeful', 'anxious', 'tired', 'confident', 'nervous', 'uncertain'];
const VALID_MIDDAY_MOODS: MiddayMood[] = ['better than expected', 'as expected', 'harder than expected', 'stressful'];
const VALID_EVENING_MOODS: EveningMood[] = ['great day', 'good day', 'challenging day', 'difficult day'];
const VALID_MORNING_FOLLOWUPS: MorningFollowUp[] = ['yes', 'no', 'somewhat'];
const VALID_MIDDAY_FOLLOWUPS: MiddayFollowUp[] = ['encouragement', 'peace', 'strength', 'wisdom'];
const VALID_EVENING_FOLLOWUPS: EveningFollowUp[] = ['hopeful', 'nervous', 'uncertain', 'ready'];
const VALID_TRANSLATIONS: Translation[] = ['ESV', 'KJV', 'NIV', 'NKJV', 'NASB', 'CSB', 'NLT'];

/**
 * Validates check-in type.
 */
export function validateCheckInType(value: unknown): CheckInType | undefined {
  if (typeof value !== 'string') return undefined;
  return VALID_CHECK_IN_TYPES.includes(value as CheckInType) ? (value as CheckInType) : undefined;
}

/**
 * Validates mood based on check-in type.
 */
export function validateMood(checkInType: CheckInType, mood: unknown): string | undefined {
  if (typeof mood !== 'string') return undefined;
  const moodLower = mood.toLowerCase();

  switch (checkInType) {
    case 'morning':
      return VALID_MORNING_MOODS.includes(moodLower as MorningMood) ? moodLower : undefined;
    case 'midday':
      return VALID_MIDDAY_MOODS.includes(moodLower as MiddayMood) ? moodLower : undefined;
    case 'evening':
      return VALID_EVENING_MOODS.includes(moodLower as EveningMood) ? moodLower : undefined;
    default:
      return undefined;
  }
}

/**
 * Validates follow-up response based on check-in type.
 */
export function validateFollowUp(checkInType: CheckInType, followUp: unknown): string | undefined {
  if (typeof followUp !== 'string') return undefined;
  const followUpLower = followUp.toLowerCase();

  switch (checkInType) {
    case 'morning':
      return VALID_MORNING_FOLLOWUPS.includes(followUpLower as MorningFollowUp) ? followUpLower : undefined;
    case 'midday':
      return VALID_MIDDAY_FOLLOWUPS.includes(followUpLower as MiddayFollowUp) ? followUpLower : undefined;
    case 'evening':
      return VALID_EVENING_FOLLOWUPS.includes(followUpLower as EveningFollowUp) ? followUpLower : undefined;
    default:
      return undefined;
  }
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
 * Validates mood check-in input.
 */
export function validateMoodCheckInInput(input: unknown): MoodCheckInInput | undefined {
  if (!input || typeof input !== 'object') return undefined;

  const obj = input as Record<string, unknown>;

  const checkInType = validateCheckInType(obj.checkInType);
  if (!checkInType) return undefined;

  const primaryMood = validateMood(checkInType, obj.primaryMood);
  if (!primaryMood) return undefined;

  const followUpResponse = validateFollowUp(checkInType, obj.followUpResponse);
  if (!followUpResponse) return undefined;

  return {
    checkInType,
    primaryMood,
    followUpResponse,
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
