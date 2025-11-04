export function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable ${name}`);
  }

  return value;
}

export const TABLE_NAME = requireEnv('TABLE_NAME');
