import {
  DeleteSecretCommand,
  GetSecretValueCommand,
  ListSecretsCommand,
  SecretsManagerClient,
} from '@aws-sdk/client-secrets-manager';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, PutCommand } from '@aws-sdk/lib-dynamodb';

const REGION =
  process.env.AWS_REGION ?? process.env.AWS_DEFAULT_REGION ?? 'us-east-1';
const TABLE_NAME = process.env.TABLE_NAME ?? 'walkworthy';
const SECRET_PREFIX = process.env.SECRET_PREFIX ?? 'walkworthy/canvas/user/';
const DRY_RUN = (process.env.DRY_RUN ?? 'false').toLowerCase() === 'true';
const RECOVERY_DAYS = process.env.RECOVERY_DAYS ?? '7';

const secrets = new SecretsManagerClient({ region: REGION });
const dynamo = DynamoDBDocumentClient.from(new DynamoDBClient({ region: REGION }), {
  marshallOptions: { removeUndefinedValues: true },
});

type CanvasSecretPayload = {
  access_token?: string;
  refresh_token?: string;
  expires_at?: string | number;
  [key: string]: unknown;
};

async function listCanvasSecretNames(): Promise<string[]> {
  const names: string[] = [];
  let nextToken: string | undefined;

  do {
    const { SecretList, NextToken } = await secrets.send(
      new ListSecretsCommand({
        Filters: [{ Key: 'name', Values: [SECRET_PREFIX] }],
        NextToken: nextToken,
        MaxResults: 100,
      }),
    );

    for (const secret of SecretList ?? []) {
      if (secret.Name && secret.Name.startsWith(SECRET_PREFIX)) {
        names.push(secret.Name);
      }
    }

    nextToken = NextToken;
  } while (nextToken);

  return names;
}

function toUserId(secretName: string): string | null {
  if (!secretName.startsWith(SECRET_PREFIX)) return null;
  return secretName.slice(SECRET_PREFIX.length);
}

function toIsoDate(value?: string | number): string | undefined {
  if (value === undefined || value === null) return undefined;
  const date =
    typeof value === 'number'
      ? new Date(value * 1000)
      : new Date(value as string);
  const iso = date.toISOString();
  return iso;
}

async function migrateOne(secretName: string): Promise<void> {
  const userId = toUserId(secretName);
  if (!userId) {
    console.warn(`Skipping secret without expected prefix: ${secretName}`);
    return;
  }

  const { SecretString } = await secrets.send(
    new GetSecretValueCommand({ SecretId: secretName }),
  );

  if (!SecretString) {
    console.warn(`Secret has no string value, skipping: ${secretName}`);
    return;
  }

  let payload: CanvasSecretPayload | null = null;
  try {
    payload = JSON.parse(SecretString) as CanvasSecretPayload;
  } catch {
    console.warn(`Secret value not JSON, storing raw string for ${secretName}`);
  }

  const now = new Date().toISOString();
  const item: Record<string, unknown> = {
    pk: `USER#${userId}`,
    sk: 'CANVAS_TOKEN',
    provider: 'canvas',
    migratedAt: now,
    migratedFromSecret: secretName,
  };

  if (payload) {
    if (payload.access_token) item.accessToken = payload.access_token;
    if (payload.refresh_token) item.refreshToken = payload.refresh_token;
    const expiresAt = toIsoDate(payload.expires_at);
    if (expiresAt) item.expiresAt = expiresAt;
    item.rawPayload = payload;
  } else {
    item.rawSecretString = SecretString;
  }

  console.log(`Migrating ${secretName} -> Dynamo item for user ${userId}`);
  if (!DRY_RUN) {
    await dynamo.send(
      new PutCommand({
        TableName: TABLE_NAME,
        Item: item,
      }),
    );
  }

  const recoveryDays = Number.parseInt(RECOVERY_DAYS, 10);
  const deleteParams =
    Number.isFinite(recoveryDays) && recoveryDays >= 7
      ? { SecretId: secretName, RecoveryWindowInDays: recoveryDays }
      : { SecretId: secretName, ForceDeleteWithoutRecovery: true };

  console.log(
    `Deleting ${secretName} (${DRY_RUN ? 'dry-run' : 'executing'})` +
      (Number.isFinite(recoveryDays) && recoveryDays > 0
        ? ` with ${recoveryDays} day recovery`
        : ' with no recovery window'),
  );

  if (!DRY_RUN) {
    await secrets.send(new DeleteSecretCommand(deleteParams));
  }
}

async function main() {
  console.log(
    `Starting migration from Secrets Manager (${SECRET_PREFIX}*) to DynamoDB table ${TABLE_NAME}`,
    { region: REGION, dryRun: DRY_RUN, recoveryDays: RECOVERY_DAYS },
  );

  const secretNames = await listCanvasSecretNames();
  if (secretNames.length === 0) {
    console.log('No matching secrets found; nothing to migrate.');
    return;
  }

  let migratedCount = 0;
  let failedCount = 0;

  for (const name of secretNames) {
    try {
      await migrateOne(name);
      migratedCount += 1;
    } catch (error) {
      console.error(`Failed to migrate ${name}`, error);
      failedCount += 1;
    }
  }

  console.log('Migration complete', {
    attempted: secretNames.length,
    migrated: migratedCount,
    failed: failedCount,
  });
}

main().catch((error) => {
  console.error('Migration failed', error);
  process.exitCode = 1;
});
