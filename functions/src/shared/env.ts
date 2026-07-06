/**
 * Environment variable configuration for Firebase Functions
 *
 * SECURITY NOTE: Sensitive values (API keys, peppers) should NEVER be exported here.
 * They must be fetched from Google Cloud Secret Manager at runtime.
 */

export const TABLE_NAME = process.env.FIRESTORE_COLLECTION || 'users';
export const GCP_PROJECT = process.env.GCP_PROJECT || process.env.GCLOUD_PROJECT;

// SECURITY: Only export secret NAME, never the actual key
// The actual key must be retrieved via getSecretString() from secrets.ts
export const OPENAI_API_KEY_SECRET_NAME = process.env.OPENAI_API_KEY_SECRET_NAME;
