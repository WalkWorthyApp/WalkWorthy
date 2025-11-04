import type { APIGatewayProxyEventV2 } from 'aws-lambda';
import { GetCommand, PutCommand, DeleteCommand } from '@aws-sdk/lib-dynamodb';
import { createHash } from 'crypto';

import { dynamo } from '../shared/dynamo';
import { getUserSub } from '../shared/auth';
import { badRequest, internalError, json, noContent, unauthorized } from '../shared/http';
import { TABLE_NAME } from '../shared/env';
import { nowIso } from '../shared/time';

type CalendarLinkStatus = 'ACTIVE' | 'PENDING' | 'ERROR' | 'MIGRATION_REQUIRED';

interface CalendarLinkRecord {
  calendarUrl: string;
  calendarHost: string;
  status: CalendarLinkStatus;
  lastValidatedAt?: string;
  lastError?: string | null;
  createdAt: string;
  updatedAt: string;
  urlHash: string;
  lastSyncedAt?: string;
  lastSyncStatus?: 'SUCCESS' | 'ERROR';
  lastSyncError?: string | null;
}

const CALENDAR_ITEM_SK = 'CALENDAR_LINK';

export async function handler(event: APIGatewayProxyEventV2) {
  try {
    const sub = getUserSub(event);
    if (!sub) {
      return unauthorized();
    }

    const method = event.requestContext.http?.method ?? '';
    switch (method.toUpperCase()) {
      case 'GET':
        return await handleGet(sub);
      case 'PUT':
        return await handlePut(sub, event);
      case 'DELETE':
        return await handleDelete(sub);
      default:
        return badRequest('Unsupported method');
    }
  } catch (error) {
    console.error('calendarLink handler failed', error);
    if (error instanceof SyntaxError) {
      return badRequest('Invalid JSON payload');
    }
    return internalError();
  }
}

async function handleGet(sub: string) {
  const record = await loadCalendarLink(sub);

  if (!record) {
    return json(200, {
      status: 'PENDING',
    });
  }

  return json(200, toResponse(record));
}

async function handlePut(sub: string, event: APIGatewayProxyEventV2) {
  const body = parseBody(event);
  if (!body.calendarUrl) {
    return badRequest('calendarUrl is required');
  }

  const sanitizedUrl = sanitizeCalendarUrl(body.calendarUrl);
  if (!sanitizedUrl.valid) {
    return badRequest(sanitizedUrl.error ?? 'Invalid calendar URL');
  }

  const validation = await validateCalendarFeed(sanitizedUrl.url);
  if (!validation.valid) {
    return badRequest(validation.error ?? 'Calendar link could not be validated');
  }

  const host = sanitizedUrl.host;
  const now = nowIso();
  const existing = await loadCalendarLink(sub);
  const createdAt = existing?.createdAt ?? now;

  const record: CalendarLinkRecord = {
    calendarUrl: sanitizedUrl.url,
    calendarHost: host,
    status: 'ACTIVE',
    lastValidatedAt: now,
    lastError: null,
    createdAt,
    updatedAt: now,
    urlHash: hashUrl(sanitizedUrl.url),
    lastSyncedAt: existing?.lastSyncedAt,
    lastSyncStatus: existing?.lastSyncStatus,
    lastSyncError: existing?.lastSyncError,
  };

  await dynamo.send(
    new PutCommand({
      TableName: TABLE_NAME,
      Item: {
        pk: toPartitionKey(sub),
        sk: CALENDAR_ITEM_SK,
        ...record,
      },
    }),
  );

  return json(200, toResponse(record));
}

async function handleDelete(sub: string) {
  await dynamo.send(
    new DeleteCommand({
      TableName: TABLE_NAME,
      Key: {
        pk: toPartitionKey(sub),
        sk: CALENDAR_ITEM_SK,
      },
    }),
  );

  return noContent();
}

function parseBody(event: APIGatewayProxyEventV2): { calendarUrl?: string } {
  if (!event.body) {
    return {};
  }

  const raw = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString('utf8') : event.body;
  return JSON.parse(raw) as { calendarUrl?: string };
}

async function loadCalendarLink(sub: string): Promise<CalendarLinkRecord | null> {
  const result = await dynamo.send(
    new GetCommand({
      TableName: TABLE_NAME,
      Key: {
        pk: toPartitionKey(sub),
        sk: CALENDAR_ITEM_SK,
      },
    }),
  );

  if (!result.Item) {
    return null;
  }

  const item = result.Item as Record<string, any>;
  return {
    calendarUrl: String(item.calendarUrl),
    calendarHost: String(item.calendarHost ?? ''),
    status: (item.status as CalendarLinkStatus) ?? 'PENDING',
    lastValidatedAt: item.lastValidatedAt as string | undefined,
    lastError: (item.lastError as string | null | undefined) ?? null,
    createdAt: item.createdAt as string,
    updatedAt: item.updatedAt as string,
    urlHash: String(item.urlHash ?? ''),
    lastSyncedAt: item.lastSyncedAt as string | undefined,
    lastSyncStatus: item.lastSyncStatus as ('SUCCESS' | 'ERROR') | undefined,
    lastSyncError: (item.lastSyncError as string | null | undefined) ?? null,
  };
}

function toResponse(record: CalendarLinkRecord) {
  return {
    calendarUrl: record.calendarUrl,
    status: record.status,
    lastValidatedAt: record.lastValidatedAt,
    lastError: record.lastError,
    updatedAt: record.updatedAt,
    lastSyncedAt: record.lastSyncedAt,
    lastSyncStatus: record.lastSyncStatus,
    lastSyncError: record.lastSyncError,
  };
}

function sanitizeCalendarUrl(raw: string): { valid: true; url: string; host: string } | { valid: false; error?: string } {
  const trimmed = raw.trim();
  if (!trimmed) {
    return { valid: false, error: 'calendarUrl is required' };
  }

  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    return { valid: false, error: 'calendarUrl must be a valid https URL ending in .ics' };
  }

  const scheme = parsed.protocol.replace(':', '').toLowerCase();
  if (scheme !== 'https') {
    return { valid: false, error: 'calendarUrl must start with https://' };
  }

  const host = parsed.hostname.toLowerCase();
  if (!host) {
    return { valid: false, error: 'calendarUrl must include a Canvas host' };
  }

  if (!parsed.pathname.toLowerCase().includes('.ics')) {
    return { valid: false, error: 'Canvas calendar links end in .ics — paste the Calendar Feed URL' };
  }

  if (!isAllowedHost(host)) {
    return { valid: false, error: 'That Canvas host is not allowed for this deployment.' };
  }

  parsed.hash = '';
  return { valid: true, url: parsed.toString(), host };
}

function isAllowedHost(host: string): boolean {
  const raw = process.env.CANVAS_ALLOWED_HOSTS;
  if (!raw || raw.trim().length === 0) {
    return true;
  }

  const allowed = raw
    .split(',')
    .map((entry) => entry.trim().toLowerCase())
    .filter((entry) => entry.length > 0);

  if (allowed.length === 0) {
    return true;
  }

  return allowed.some((candidate) => host === candidate || host.endsWith(`.${candidate}`));
}

async function validateCalendarFeed(url: string): Promise<{ valid: true } | { valid: false; error?: string }> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);

  try {
    const response = await fetch(url, {
      method: 'GET',
      headers: {
        'User-Agent': 'WalkWorthy/1.0 (+https://walkworthy.app)',
        'Cache-Control': 'no-cache',
      },
      signal: controller.signal,
    });

    if (!response.ok) {
      return { valid: false, error: `Canvas returned ${response.status}` };
    }

    const text = await response.text();
    if (!text.includes('BEGIN:VCALENDAR')) {
      return { valid: false, error: 'Canvas response is not a valid iCal feed' };
    }

    return { valid: true };
  } catch (error) {
    if ((error as Error).name === 'AbortError') {
      return { valid: false, error: 'Canvas calendar request timed out' };
    }
    return { valid: false, error: 'Canvas calendar link could not be reached' };
  } finally {
    clearTimeout(timeout);
  }
}

function hashUrl(url: string): string {
  return createHash('sha256').update(url).digest('hex');
}

function toPartitionKey(sub: string): string {
  return `USER#${sub}`;
}
