import * as crypto from 'crypto';

/**
 * NOTIFICATION TOKEN SECURITY ARCHITECTURE
 *
 * This module implements cryptographic protection for push notification tokens (APNs/FCM).
 * Security is enforced through defense-in-depth across multiple layers:
 *
 * 1. HASHING (this file)
 *    - Tokens are hashed with SHA-256 + pepper before any storage/transmission
 *    - hashNotificationToken(): Convert plain token → SHA-256 hash
 *    - verifyNotificationToken(): Constant-time comparison for verification
 *    - Pepper stored in env var (must be rotated in production)
 *
 * 2. FIRESTORE RULES (../../firestore.rules)
 *    - Blocks plain 'notificationToken' field in all client writes (create/update)
 *    - Only allows 'notificationTokenHash' field (64 hex chars, validated as SHA-256)
 *    - Ensures users can only access their own devices
 *    - NOTE: Admin SDK bypasses these rules, so validation is ESSENTIAL in Cloud Functions
 *
 * 3. APPLICATION VALIDATION
 *    - isValidNotificationToken(): Validates format based on platform (iOS/Android)
 *    - Device registration endpoint MUST hash before storage
 *    - Cloud Functions MUST re-validate even when using Admin SDK
 *
 * 4. LOGGING & REDACTION
 *    - redactSensitiveFields(): Removes sensitive data from logs
 *    - Never log plain tokens; use hashes for tracing
 *    - TTL/rotation: 90-day retention policy (enforced at application level)
 *    - Delete on uninstall/opt-out (Cloud Functions responsibility)
 *
 * COMPLIANCE:
 * - APNs: Follows Apple's security guidelines for token handling
 * - FCM: Follows Google's token security requirements
 * - PCI-DSS: If payment is involved, token storage must be PCI compliant
 */

/**
 * Hash a notification token for secure storage.
 * Uses SHA-256 with a pepper from environment to prevent rainbow table attacks.
 *
 * @param token - The plain notification token (APNs/FCM)
 * @returns Hashed token as hex string (64 hex characters)
 * @throws Error if NOTIFICATION_TOKEN_PEPPER environment variable is not set
 */
export function hashNotificationToken(token: string): string {
  const pepper = process.env.NOTIFICATION_TOKEN_PEPPER;
  if (!pepper) {
    throw new Error(
      'NOTIFICATION_TOKEN_PEPPER environment variable must be set. ' +
      'This is required for secure token hashing in production.'
    );
  }

  const hash = crypto.createHash('sha256');
  hash.update(token + pepper);
  return hash.digest('hex');
}

/**
 * Verify a notification token matches a stored hash.
 *
 * @param token - The plain notification token to verify
 * @param storedHash - The stored hash to compare against
 * @returns True if token matches the hash
 */
export function verifyNotificationToken(token: string, storedHash: string): boolean {
  // Validate inputs to prevent crashes and timing attacks
  if (!storedHash || storedHash.length !== 64) {
    return false;
  }

  const tokenHash = hashNotificationToken(token);

  try {
    return crypto.timingSafeEqual(
      Buffer.from(tokenHash, 'hex'),
      Buffer.from(storedHash, 'hex')
    );
  } catch (error) {
    // Buffer creation can fail if not valid hex
    return false;
  }
}

/**
 * Redact sensitive data from objects for logging.
 * Replaces sensitive fields with '[REDACTED]'.
 *
 * @param obj - Object containing potentially sensitive data
 * @returns Sanitized copy of the object safe for logging
 */
export function redactSensitiveFields<T extends Record<string, any>>(obj: T): T {
  const sensitiveFields = [
    'notificationToken',
    'notification_token',
    'pushToken',
    'push_token',
    'deviceToken',
    'device_token',
    'fcmToken',
    'apnsToken',
    'password',
    'secret',
    'apiKey',
    'api_key',
    'accessToken',
    'access_token',
    'refreshToken',
    'refresh_token',
  ];

  const redacted = { ...obj } as any;

  for (const key of Object.keys(redacted)) {
    if (sensitiveFields.some(field => key.toLowerCase().includes(field.toLowerCase()))) {
      redacted[key] = '[REDACTED]';
    } else if (typeof redacted[key] === 'object' && redacted[key] !== null) {
      redacted[key] = redactSensitiveFields(redacted[key]);
    }
  }

  return redacted as T;
}

/**
 * Validate notification token format.
 *
 * @param token - Token to validate
 * @param platform - Device platform ('ios' or 'android')
 * @returns True if token format is valid
 */
export function isValidNotificationToken(token: string, platform: 'ios' | 'android'): boolean {
  if (!token || typeof token !== 'string') {
    return false;
  }

  // APNs tokens are 64 hex characters
  if (platform === 'ios') {
    return /^[a-f0-9]{64}$/i.test(token);
  }

  // FCM tokens are typically 152+ characters (base64-like) with colon-separated segments
  if (platform === 'android') {
    return token.length >= 140 && /^[\w-]+(?::[\w-]+)+$/i.test(token);
  }

  return false;
}
