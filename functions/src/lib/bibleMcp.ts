import { LambdaClient, InvokeCommand } from '@aws-sdk/client-lambda';

type Verse = {
  ref: string;
  text: string;
  translation?: string;
  tags?: string[];
};

export interface BibleMcpOptions {
  mode: 'http' | 'lambda' | 'stdio' | 'disabled';
  url?: string;
  defaultTranslation?: string;
  cmd?: string;
  args?: string[];
  lambdaArn?: string;
}

const lambdaClient = new LambdaClient({});
const BIBLE_MCP_FETCH_TIMEOUT_MS = 5000;

export class BibleMcpProvider {
  constructor(private readonly opts: BibleMcpOptions) {}

  async searchByKeywords(keywords: string[], translation?: string, limit = 5): Promise<Verse[]> {
    if (this.opts.mode === 'disabled') return [];
    const tx = translation || this.opts.defaultTranslation || 'ESV';

    if (this.opts.mode === 'http') {
      if (!this.opts.url) throw new Error('BIBLE_MCP_URL is required for http mode');
      // JSON-RPC style call; adjust to your bridge's schema if different
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), BIBLE_MCP_FETCH_TIMEOUT_MS);

      try {
        const res = await fetch(this.opts.url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: '1',
            method: 'search_verses',
            params: { keywords, translation: tx, limit },
          }),
          signal: controller.signal,
        });
        if (!res.ok) throw new Error(`Bible MCP HTTP error: ${res.status}`);
        const json: any = await res.json();
        return (json?.result ?? []) as Verse[];
      } catch (error) {
        if (error instanceof Error && error.name === 'AbortError') {
          throw new Error(`Bible MCP search_verses request timed out after ${BIBLE_MCP_FETCH_TIMEOUT_MS}ms`);
        }
        throw error;
      } finally {
        clearTimeout(timeout);
      }
    }

    if (this.opts.mode === 'lambda') {
      if (!this.opts.lambdaArn) throw new Error('BIBLE_MCP_LAMBDA_ARN is required for lambda mode');
      const response = await lambdaClient.send(
        new InvokeCommand({
          FunctionName: this.opts.lambdaArn,
          Payload: Buffer.from(
            JSON.stringify({
              jsonrpc: '2.0',
              id: '1',
              method: 'search_verses',
              params: { keywords, translation: tx, limit },
            }),
          ),
        }),
      );
      if (!response.Payload) return [];
      const payload = JSON.parse(Buffer.from(response.Payload).toString('utf-8')) as {
        result?: Verse[];
        error?: { message?: string };
      };
      if (payload.error) throw new Error(payload.error.message ?? 'Bible MCP lambda error');
      return (payload.result ?? []) as Verse[];
    }

    // stdio mode is typically used locally. Implement MCP stdio protocol if needed.
    throw new Error('BIBLE_MCP_MODE=stdio not implemented in this Lambda scaffold');
  }

  async getByReference(ref: string, translation?: string): Promise<Verse | null> {
    if (this.opts.mode === 'disabled') return null;
    const tx = translation || this.opts.defaultTranslation || 'ESV';

    if (this.opts.mode === 'http') {
      if (!this.opts.url) throw new Error('BIBLE_MCP_URL is required for http mode');
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), BIBLE_MCP_FETCH_TIMEOUT_MS);

      try {
        const res = await fetch(this.opts.url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: '1',
            method: 'get_verse_by_reference',
            params: { ref, translation: tx },
          }),
          signal: controller.signal,
        });
        if (!res.ok) throw new Error(`Bible MCP HTTP error: ${res.status}`);
        const json: any = await res.json();
        return (json?.result ?? null) as Verse | null;
      } catch (error) {
        if (error instanceof Error && error.name === 'AbortError') {
          throw new Error(`Bible MCP get_verse_by_reference request timed out after ${BIBLE_MCP_FETCH_TIMEOUT_MS}ms`);
        }
        throw error;
      } finally {
        clearTimeout(timeout);
      }
    }

    if (this.opts.mode === 'lambda') {
      if (!this.opts.lambdaArn) throw new Error('BIBLE_MCP_LAMBDA_ARN is required for lambda mode');
      const response = await lambdaClient.send(
        new InvokeCommand({
          FunctionName: this.opts.lambdaArn,
          Payload: Buffer.from(
            JSON.stringify({
              jsonrpc: '2.0',
              id: '1',
              method: 'get_verse_by_reference',
              params: { ref, translation: tx },
            }),
          ),
        }),
      );
      if (!response.Payload) return null;
      const payload = JSON.parse(Buffer.from(response.Payload).toString('utf-8')) as {
        result?: Verse | null;
        error?: { message?: string };
      };
      if (payload.error) throw new Error(payload.error.message ?? 'Bible MCP lambda error');
      return (payload.result ?? null) as Verse | null;
    }

    throw new Error('BIBLE_MCP_MODE=stdio not implemented in this Lambda scaffold');
  }
}

export function bibleMcpFromEnv(): BibleMcpProvider {
  const mode = (process.env.BIBLE_MCP_MODE || 'disabled') as BibleMcpOptions['mode'];
  const url = process.env.BIBLE_MCP_URL;
  const defaultTranslation = process.env.BIBLE_MCP_DEFAULT_TRANSLATION || 'ESV';
  const cmd = process.env.BIBLE_MCP_CMD;
  const args = safeParseJsonArray(process.env.BIBLE_MCP_ARGS);
  const lambdaArn = process.env.BIBLE_MCP_LAMBDA_ARN;

  return new BibleMcpProvider({ mode, url, defaultTranslation, cmd, args, lambdaArn });
}

function safeParseJsonArray(input?: string): string[] | undefined {
  if (!input) return undefined;
  try {
    const val = JSON.parse(input);
    return Array.isArray(val) ? (val as string[]) : undefined;
  } catch {
    return undefined;
  }
}
