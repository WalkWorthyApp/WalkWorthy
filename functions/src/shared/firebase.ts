import { initializeApp, getApps, App } from 'firebase-admin/app';
import { getFirestore, Firestore } from 'firebase-admin/firestore';
import { getAuth, Auth } from 'firebase-admin/auth';
import { getAppCheck, AppCheck } from 'firebase-admin/app-check';

let app: App | undefined;
let firestoreInstance: Firestore | undefined;
let authInstance: Auth | undefined;
let appCheckInstance: AppCheck | undefined;

/**
 * Initialize Firebase Admin SDK.
 * Safe to call multiple times - will only initialize once.
 */
export function initializeFirebase(): App {
  if (app) return app;

  const apps = getApps();
  if (apps.length > 0) {
    app = apps[0];
    return app;
  }

  app = initializeApp();
  return app;
}

/**
 * Get Firestore instance.
 * Automatically initializes Firebase if needed.
 */
export function getDb(): Firestore {
  if (firestoreInstance) return firestoreInstance;
  initializeFirebase();
  firestoreInstance = getFirestore();
  return firestoreInstance;
}

/**
 * Get Firebase Auth instance.
 * Automatically initializes Firebase if needed.
 */
export function getAuthInstance(): Auth {
  if (authInstance) return authInstance;
  initializeFirebase();
  authInstance = getAuth();
  return authInstance;
}

/**
 * Get Firebase App Check instance.
 * Automatically initializes Firebase if needed.
 */
export function getAppCheckInstance(): AppCheck {
  if (appCheckInstance) return appCheckInstance;
  initializeFirebase();
  appCheckInstance = getAppCheck();
  return appCheckInstance;
}

/**
 * Collection paths for consistent access
 */
export const COLLECTIONS = {
  users: 'users',
  profile: (userId: string) => `users/${userId}/profile`,
  calendar: (userId: string) => `users/${userId}/calendar`,
  moodCheckIns: (userId: string) => `users/${userId}/moodCheckIns`,
  moodSummaries: (userId: string) => `users/${userId}/moodSummaries`,
  dailyReflections: (userId: string) => `users/${userId}/dailyReflections`,
  journalEntries: (userId: string) => `users/${userId}/journalEntries`,
} as const;
