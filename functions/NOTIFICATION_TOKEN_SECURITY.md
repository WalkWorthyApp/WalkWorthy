# Notification Token Security Implementation

## Overview

Push notification tokens (APNs for iOS, FCM for Android) are sensitive device-specific data that must be handled securely to protect user privacy and comply with platform policies.

## Security Measures Implemented

### 1. Token Hashing

**Plain tokens are NEVER stored in the database.**

- All notification tokens are hashed using SHA-256 with a pepper before storage
- Hash function: `hashNotificationToken()` in `shared/crypto.ts`
- Pepper stored in environment variable `NOTIFICATION_TOKEN_PEPPER`
- Stored field: `notificationTokenHash` (not `notificationToken`)

```typescript
// ✅ Correct - token is hashed
const hash = hashNotificationToken(token);
await deviceRef.set({ notificationTokenHash: hash });

// ❌ Wrong - never store plain tokens
await deviceRef.set({ notificationToken: token });
```

### 2. Logging Redaction

**Sensitive fields are automatically redacted from logs.**

- Use `redactSensitiveFields()` before logging any object
- Replaces sensitive fields with `[REDACTED]`
- Prevents accidental token exposure in logs

```typescript
// ✅ Correct - data is redacted
logger.info('Device registration', {
  data: redactSensitiveFields(input)
});

// ❌ Wrong - may log plain tokens
logger.info('Device registration', { data: input });
```

### 3. Token Validation

**All tokens are validated before acceptance.**

- iOS (APNs): Must be 64 hex characters
- Android (FCM): Must be 140+ characters in FCM format
- Invalid tokens are rejected with error

```typescript
if (!isValidNotificationToken(token, platform)) {
  throw new Error('Invalid notification token format');
}
```

### 4. Access Control

**Firestore security rules enforce least-privilege access.**

- Users can only access their own devices
- Plain `notificationToken` field is explicitly blocked
- Only `notificationTokenHash` can be stored
- Cloud Functions use Admin SDK (bypasses rules)

```javascript
// Firestore rule prevents storing plain tokens
allow create: if (!request.resource.data.keys().hasAny(['notificationToken']));
```

### 5. Token Retention Policy

**Tokens are automatically cleaned up after 90 days.**

- Tokens older than 90 days are removed via scheduled function
- Implements `cleanupExpiredTokens()` in `shared/device.ts`
- Reduces risk from stale/leaked tokens

### 6. Token Revocation

**Users can opt-out or uninstall without data retention.**

- `revokeDeviceToken()`: Removes hash, disables notifications
- `deleteDevice()`: Completely removes device record
- Supports user privacy rights (GDPR, etc.)

## Environment Variables Required

```bash
# Cryptographic pepper for token hashing
# MUST be changed in production and kept secret
NOTIFICATION_TOKEN_PEPPER=your-secret-pepper-here

# GCP project ID for Cloud Functions
GCP_PROJECT=your-gcp-project-id
```

## API Usage

### Register/Update Device

```typescript
import { registerDevice } from './shared/device';

await registerDevice(userId, {
  deviceId: 'unique-device-id',
  platform: 'ios', // or 'android'
  appVersion: '1.0.0',
  notificationToken: 'user-apns-or-fcm-token', // Will be hashed
});
```

### Revoke Token (User Opt-Out)

```typescript
import { revokeDeviceToken } from './shared/device';

await revokeDeviceToken(userId, deviceId);
```

### Delete Device (App Uninstall)

```typescript
import { deleteDevice } from './shared/device';

await deleteDevice(userId, deviceId);
```

### Get User Devices

```typescript
import { getUserDevices } from './shared/device';

const devices = await getUserDevices(userId);
// Returns devices with hashed tokens only
```

## Compliance

### APNs (Apple Push Notification Service)

- ✅ Tokens stored securely (hashed)
- ✅ Tokens validated before use
- ✅ Tokens deleted on uninstall
- ✅ User consent required (implicit via token provision)

### FCM (Firebase Cloud Messaging)

- ✅ Tokens stored securely (hashed)
- ✅ Tokens validated before use
- ✅ Tokens deleted on uninstall
- ✅ User consent required (implicit via token provision)

### GDPR / Privacy Laws

- ✅ Data minimization (only hash stored)
- ✅ Right to deletion (revokeDeviceToken/deleteDevice)
- ✅ Data retention limits (90-day policy)
- ✅ Access control (users own their data)

## Scheduled Maintenance

Run token cleanup periodically (recommended: daily):

```typescript
// Cloud Function scheduled to run daily
export const cleanupTokens = onSchedule('every day 00:00', async () => {
  const users = await getAllUserIds(); // Your user query
  for (const userId of users) {
    await cleanupExpiredTokens(userId);
  }
});
```

## Testing

To verify security implementation:

1. **Hash Verification**: Token hashes should be deterministic
   ```typescript
   const hash1 = hashNotificationToken('test-token');
   const hash2 = hashNotificationToken('test-token');
   assert(hash1 === hash2);
   ```

2. **Logging Redaction**: Logs should not contain plain tokens
   ```typescript
   const redacted = redactSensitiveFields({ notificationToken: 'secret' });
   assert(redacted.notificationToken === '[REDACTED]');
   ```

3. **Firestore Rules**: Attempt to write plain token should fail
   ```typescript
   // Should be rejected by security rules
   await db.collection('users/uid/devices/did').set({
     notificationToken: 'plain-token' // ❌ Blocked
   });
   ```

## Migration from Plain Storage

If you previously stored plain tokens:

1. **Read all existing devices**
2. **Hash the plain tokens**
3. **Update with hashed versions**
4. **Delete plain token field**

```typescript
// Example migration script
const devices = await db.collection('users/uid/devices').get();
for (const doc of devices.docs) {
  const data = doc.data();
  if (data.notificationToken) {
    const hash = hashNotificationToken(data.notificationToken);
    await doc.ref.update({
      notificationTokenHash: hash,
      notificationToken: FieldValue.delete(),
    });
  }
}
```

## Security Checklist

- [ ] `NOTIFICATION_TOKEN_PEPPER` set in environment
- [ ] All token storage uses `hashNotificationToken()`
- [ ] All logging uses `redactSensitiveFields()`
- [ ] Token validation before acceptance
- [ ] Firestore rules block plain token storage
- [ ] Token cleanup scheduled function deployed
- [ ] User opt-out/deletion handlers implemented
- [ ] Platform compliance verified (APNs/FCM)

## References

- [APNs Provider API](https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server)
- [FCM HTTP v1 API](https://firebase.google.com/docs/cloud-messaging/migrate-v1)
- [OWASP Sensitive Data Exposure](https://owasp.org/www-project-top-ten/2017/A3_2017-Sensitive_Data_Exposure)
