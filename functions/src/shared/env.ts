/**
 * Environment variable configuration for Firebase Functions
 */

export const TABLE_NAME = process.env.FIRESTORE_COLLECTION || 'users';
export const GCP_PROJECT = process.env.GCP_PROJECT || process.env.GCLOUD_PROJECT;
export const OPENAI_API_KEY = process.env.OPENAI_API_KEY;
export const OPENAI_API_KEY_SECRET_NAME = process.env.OPENAI_API_KEY_SECRET_NAME;
