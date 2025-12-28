import { getFirestore, FieldValue } from 'firebase-admin/firestore';
import { hashNotificationToken, isValidNotificationToken, redactSensitiveFields } from './crypto';
import { DeviceRegistrationInput } from './types';
import { logger } from 'firebase-functions/v2';

export interface StoredDevice {
  deviceId: string;
  platform: 'ios' | 'android';
  appVersion?: string;
  /** Hashed notification token - never store plain tokens */
  notificationTokenHash?: string;
  /** Token expiration/rotation tracking */
  tokenUpdatedAt?: string;
  /** Device registration timestamp */
  registeredAt: string;
  /** Last active timestamp */
  lastActiveAt: string;
  /** User consent for notifications */
  notificationsEnabled: boolean;
}

/**
 * Token retention policy: 90 days
 * Tokens older than this should be rotated or removed
 */
const TOKEN_RETENTION_DAYS = 90;

/**
 * Register or update a device with secure token handling.
 *
 * @param userId - The authenticated user ID
 * @param input - Device registration data
 * @throws Error if token validation fails or storage fails
 */
export async function registerDevice(
  userId: string,
  input: DeviceRegistrationInput
): Promise<void> {
  const { deviceId, platform, appVersion, notificationToken } = input;

  // Log registration attempt with redacted data
  logger.info('Device registration attempt', {
    userId,
    deviceId,
    platform,
    data: redactSensitiveFields(input),
  });

  // Validate notification token if provided
  if (notificationToken) {
    if (!isValidNotificationToken(notificationToken, platform)) {
      logger.warn('Invalid notification token format', {
        userId,
        deviceId,
        platform,
      });
      throw new Error(`Invalid notification token format for platform: ${platform}`);
    }
  }

  const db = getFirestore();
  const deviceRef = db.collection('users').doc(userId).collection('devices').doc(deviceId);

  // Prepare device data with hashed token
  const now = new Date().toISOString();
  const deviceData: Partial<StoredDevice> = {
    deviceId,
    platform,
    appVersion,
    lastActiveAt: now,
  };

  // Only hash and store token if provided (updates may not include token)
  if (notificationToken) {
    deviceData.notificationTokenHash = hashNotificationToken(notificationToken);
    deviceData.tokenUpdatedAt = now;
    deviceData.notificationsEnabled = true; // User provided token = consent
  }

  // Check if device exists
  const deviceSnap = await deviceRef.get();

  if (deviceSnap.exists) {
    // Update existing device
    await deviceRef.update({
      ...deviceData,
      // Don't overwrite registeredAt
    } as any);

    logger.info('Device updated successfully', {
      userId,
      deviceId,
      platform,
      tokenProvided: !!notificationToken,
    });
  } else {
    // Register new device
    await deviceRef.set({
      ...deviceData,
      registeredAt: now,
      notificationsEnabled: !!notificationToken,
    } as StoredDevice);

    logger.info('Device registered successfully', {
      userId,
      deviceId,
      platform,
      tokenProvided: !!notificationToken,
    });
  }
}

/**
 * Revoke device notifications (e.g., on app uninstall or user opt-out).
 *
 * @param userId - The authenticated user ID
 * @param deviceId - The device to revoke
 */
export async function revokeDeviceToken(userId: string, deviceId: string): Promise<void> {
  const db = getFirestore();
  const deviceRef = db.collection('users').doc(userId).collection('devices').doc(deviceId);

  await deviceRef.update({
    notificationTokenHash: FieldValue.delete(),
    tokenUpdatedAt: FieldValue.delete(),
    notificationsEnabled: false,
    lastActiveAt: new Date().toISOString(),
  });

  logger.info('Device token revoked', { userId, deviceId });
}

/**
 * Delete a device registration entirely (e.g., on account deletion).
 *
 * @param userId - The authenticated user ID
 * @param deviceId - The device to delete
 */
export async function deleteDevice(userId: string, deviceId: string): Promise<void> {
  const db = getFirestore();
  const deviceRef = db.collection('users').doc(userId).collection('devices').doc(deviceId);

  await deviceRef.delete();

  logger.info('Device deleted', { userId, deviceId });
}

/**
 * Get all registered devices for a user (with hashed tokens only).
 *
 * @param userId - The authenticated user ID
 * @returns Array of stored devices
 */
export async function getUserDevices(userId: string): Promise<StoredDevice[]> {
  const db = getFirestore();
  const devicesSnap = await db
    .collection('users')
    .doc(userId)
    .collection('devices')
    .get();

  return devicesSnap.docs.map(doc => doc.data() as StoredDevice);
}

/**
 * Clean up expired tokens (older than retention policy).
 * Should be run periodically via scheduled Cloud Function.
 *
 * @param userId - The user to clean up tokens for
 */
export async function cleanupExpiredTokens(userId: string): Promise<number> {
  const db = getFirestore();
  const devicesRef = db.collection('users').doc(userId).collection('devices');

  const cutoffDate = new Date();
  cutoffDate.setDate(cutoffDate.getDate() - TOKEN_RETENTION_DAYS);
  const cutoffIso = cutoffDate.toISOString();

  // Find devices with old tokens
  const oldDevices = await devicesRef
    .where('tokenUpdatedAt', '<', cutoffIso)
    .get();

  // Remove expired tokens
  const batch = db.batch();
  let count = 0;

  for (const doc of oldDevices.docs) {
    batch.update(doc.ref, {
      notificationTokenHash: FieldValue.delete(),
      tokenUpdatedAt: FieldValue.delete(),
      notificationsEnabled: false,
    });
    count++;
  }

  if (count > 0) {
    await batch.commit();
    logger.info('Cleaned up expired tokens', { userId, count });
  }

  return count;
}
