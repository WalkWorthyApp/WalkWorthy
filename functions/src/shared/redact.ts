/**
 * Redact sensitive data from objects for logging.
 * Replaces sensitive fields with '[REDACTED]'.
 *
 * Matching is case-insensitive substring, so any log object that happens to
 * carry a token/credential-shaped key is scrubbed even if it isn't an exact
 * name listed below.
 *
 * @param obj - Object containing potentially sensitive data
 * @returns Sanitized copy of the object safe for logging
 */
export function redactSensitiveFields<T extends Record<string, unknown>>(obj: T): T {
  const sensitiveFields = [
    // Notification tokens (all variants)
    'notificationToken',
    'notificationTokenRaw',
    'notification_token',
    'pushToken',
    'push_token',
    'deviceToken',
    'device_token',
    'fcmToken',
    'apnsToken',
    'plainToken',
    // Credentials and secrets
    'password',
    'secret',
    'apiKey',
    'api_key',
    'privateKey',
    'private_key',
    'clientSecret',
    'client_secret',
    'serviceAccount',
    'service_account',
    'credential',
    'credentials',
    'bearer',
    // OAuth/Auth tokens
    'accessToken',
    'access_token',
    'refreshToken',
    'refresh_token',
    'idToken',
    'id_token',
    'authToken',
    'auth_token',
    'sessionId',
    'session_id',
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
