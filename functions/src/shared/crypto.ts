import * as crypto from 'crypto';
import { getSecretString } from './secrets';

/**
 * NOTIFICATION TOKEN SECURITY ARCHITECTURE
 *
 * This module implements cryptographic protection for push notification tokens (APNs/FCM).
 * Security is enforced through defense-in-depth across multiple layers:
 *
 * 1. HASHING (this file)
 *    - Tokens are hashed with SHA-256 + pepper before any storage/transmission
 *    - initializePepper(): Must be called at startup to fetch pepper from Secret Manager
 *    - hashNotificationToken(): Convert plain token → SHA-256 hash
 *    - verifyNotificationToken(): Constant-time comparison for verification
 *    - Pepper stored in Google Cloud Secret Manager (never in env vars in production)
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

// SECURITY: Pepper is cached in memory after fetch from Secret Manager
// Never stored in process.env or logged
let cachedPepper: string | null = null;
let pepperInitialized = false;
let initializingPepperPromise: Promise<void> | null = null;

/**
 * Initialize the notification token pepper from Google Cloud Secret Manager.
 * MUST be called before hashNotificationToken() or verifyNotificationToken().
 *
 * Uses a promise guard to prevent multiple concurrent Secret Manager fetches.
 * Only the first caller fetches the secret; concurrent callers await the same promise.
 *
 * @throws Error if secret name is not configured or secret cannot be retrieved
 */
async function initializePepper(): Promise<void> {
  // Fast path: Already initialized
  if (pepperInitialized && cachedPepper) {
    return;
  }

  // If initialization is already in progress, await it
  if (initializingPepperPromise) {
    return initializingPepperPromise;
  }

  // Start initialization - set promise before async operations
  initializingPepperPromise = (async () => {
    try {
      // SECURITY: Always fetch pepper from Secret Manager
      // Default secret name matches what's created in GCP Secret Manager
      const secretName = process.env.NOTIFICATION_TOKEN_PEPPER_SECRET_NAME || 'notification-token-pepper';

      const pepper = await getSecretString(secretName);
      if (!pepper) {
        throw new Error(`Failed to retrieve notification token pepper from secret: ${secretName}`);
      }

      // SECURITY: Store pepper only in module-scoped variable, never in process.env
      cachedPepper = pepper;
      pepperInitialized = true;
    } finally {
      // Clear promise after completion (success or failure)
      initializingPepperPromise = null;
    }
  })();

  return initializingPepperPromise;
}

/**
 * Ensure the notification token pepper is initialized and ready.
 *
 * This function deterministically guarantees pepper initialization before operations.
 * It should be called at the start of any request handler that needs token hashing.
 *
 * Usage:
 *   export const myHandler = onRequest(async (req, res) => {
 *     await ensurePepperInitialized();  // Guarantee pepper is ready
 *     // Now safe to call hashNotificationToken()
 *   });
 *
 * @throws Error if pepper initialization fails
 */
export async function ensurePepperInitialized(): Promise<void> {
  return initializePepper();
}

/**
 * Hash a notification token for secure storage.
 * Uses SHA-256 with a pepper from Secret Manager to prevent rainbow table attacks.
 *
 * IMPORTANT: initializePepper() must be called before using this function.
 *
 * @param token - The plain notification token (APNs/FCM)
 * @returns Hashed token as hex string (64 hex characters)
 * @throws Error if pepper has not been initialized
 */
export function hashNotificationToken(token: string): string {
  if (!cachedPepper) {
    throw new Error(
      'Notification token pepper not initialized. ' +
      'Call initializePepper() before hashing tokens.'
    );
  }

  const hash = crypto.createHash('sha256');
  hash.update(token + cachedPepper);
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
export function redactSensitiveFields<T extends Record<string, unknown>>(obj: T): T {
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

  const redacted: Record<string, unknown> = { ...obj };

  for (const key of Object.keys(redacted)) {
    if (sensitiveFields.some(field => key.toLowerCase().includes(field.toLowerCase()))) {
      redacted[key] = '[REDACTED]';
    } else if (typeof redacted[key] === 'object' && redacted[key] !== null) {
      redacted[key] = redactSensitiveFields(redacted[key] as Record<string, unknown>);
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
