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
 * - ageRange, gender, and major are SENSITIVE DATA (PII)
 * - NEVER log these fields in plain text
 * - Validate incoming values against defined enums before storage
 * - Use redactSensitiveFields() when logging this data
 * - Consider field importance before including in AI prompts
 */
export interface UserProfileInput {
  /** SENSITIVE: Must be one of the predefined age ranges */
  ageRange?: AgeRange;

  /** Optional major/field of study. May be free-form but should be validated. */
  major?: string;

  /** SENSITIVE: Must be one of the predefined gender options */
  gender?: Gender;

  hobbies?: string[];
  optInTailored: boolean;
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
 * SECURITY: Validates all fields including sensitive PII fields.
 *
 * @param input The untrusted profile input from client
 * @returns Validated and sanitized UserProfileInput or undefined if critical fields are invalid
 */
export function validateUserProfileInput(input: unknown): UserProfileInput | undefined {
  if (!input || typeof input !== 'object') return undefined;

  const obj = input as Record<string, unknown>;

  return {
    ageRange: obj.ageRange ? validateAgeRange(obj.ageRange) : undefined,
    gender: obj.gender ? validateGender(obj.gender) : undefined,
    major: typeof obj.major === 'string' ? obj.major : undefined,
    hobbies: Array.isArray(obj.hobbies)
      ? obj.hobbies.filter((h) => typeof h === 'string').slice(0, 10)
      : undefined,
    optInTailored: Boolean(obj.optInTailored),
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
