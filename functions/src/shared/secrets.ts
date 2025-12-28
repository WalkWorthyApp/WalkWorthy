import { SecretManagerServiceClient } from '@google-cloud/secret-manager';

const client = new SecretManagerServiceClient();

/**
 * Get a secret string value from Google Cloud Secret Manager.
 *
 * @param secretId - The secret name or full resource path
 * @returns The secret value as a string
 * @throws Error if the secret doesn't exist or has no string value
 */
export async function getSecretString(secretId: string): Promise<string> {
  // Construct the secret path if not already provided
  let name: string;
  if (secretId.startsWith('projects/')) {
    name = secretId;
  } else {
    // Validate that a project ID is available
    const projectId = process.env.GCP_PROJECT || process.env.GCLOUD_PROJECT;
    if (!projectId) {
      throw new Error(
        'Missing GCP project ID: set GCP_PROJECT or GCLOUD_PROJECT environment variable'
      );
    }
    name = `projects/${projectId}/secrets/${secretId}/versions/latest`;
  }

  const [version] = await client.accessSecretVersion({ name });
  const payload = version.payload?.data;

  if (!payload) {
    throw new Error(`Secret ${secretId} has no payload`);
  }

  // Convert buffer to string
  const secretValue = payload.toString();

  if (!secretValue) {
    throw new Error(`Secret ${secretId} has no string value`);
  }

  return secretValue;
}
