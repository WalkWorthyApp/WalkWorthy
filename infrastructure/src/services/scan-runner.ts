import { randomUUID } from 'crypto';

import {
  GetCommand,
  PutCommand,
  QueryCommand,
  UpdateCommand,
} from '@aws-sdk/lib-dynamodb';

import { TABLE_NAME } from '../shared/env';
import { dynamo } from '../shared/dynamo';
import { nowIso, futureEpochSeconds } from '../shared/time';
import { getUserProfileOnce } from '../shared/profile';
import { bibleMcpFromEnv } from '../lib/bibleMcp';
import { runVerseSelectionAgent } from '../lib/walkworthy-agent';
import { fetchCalendarEvents } from '../lib/calendar-ical';
import type { CalendarEventItem } from '../lib/calendar-ical';
import { mapCalendarEventsToStressfulItems, buildVerseCandidates } from '../lib/stress-heuristics';
import type {
  StressfulItem,
  VerseCandidate,
  Translation,
  UserProfilePayload,
} from '../lib/walkworthy-agent';

export type ScanStatus = 'SUCCESS' | 'FALLBACK';

export interface RunScanResult {
  encouragementId: string;
  status: ScanStatus;
  log: ScanLog;
}

export type CalendarLinkStatus = 'ACTIVE' | 'PENDING' | 'ERROR' | 'MIGRATION_REQUIRED';

export class CalendarLinkMissingError extends Error {
  readonly status?: CalendarLinkStatus;

  constructor(sub: string, status?: CalendarLinkStatus) {
    super(
      status === 'MIGRATION_REQUIRED'
        ? 'Canvas OAuth tokens are no longer supported. Paste your read-only calendar link to continue.'
        : 'Canvas calendar link not found. Add your personal Canvas calendar feed in WalkWorthy.',
    );
    this.name = 'CalendarLinkMissingError';
    this.status = status;
  }
}

async function recordCalendarSyncStatus(
  sub: string,
  status: 'SUCCESS' | 'ERROR',
  errorMessage?: string,
) {
  const now = nowIso();

  const baseParams = {
    TableName: TABLE_NAME,
    Key: {
      pk: `USER#${sub}`,
      sk: 'CANVAS_LINK',
    },
  } as const;

  try {
    if (status === 'SUCCESS') {
      await dynamo.send(
        new UpdateCommand({
          ...baseParams,
          UpdateExpression: 'SET lastSyncedAt = :at, lastSyncStatus = :status REMOVE lastSyncError',
          ExpressionAttributeValues: {
            ':at': now,
            ':status': status,
          },
        }),
      );
      console.log('scan-runner: recorded successful calendar sync', {
        sub,
        lastSyncedAt: now,
      });
    } else {
      await dynamo.send(
        new UpdateCommand({
          ...baseParams,
          UpdateExpression: 'SET lastSyncedAt = :at, lastSyncStatus = :status, lastSyncError = :error',
          ExpressionAttributeValues: {
            ':at': now,
            ':status': status,
            ':error': errorMessage ?? 'Unknown error',
          },
        }),
      );
      console.warn('scan-runner: recorded failed calendar sync', {
        sub,
        lastSyncedAt: now,
        error: errorMessage,
      });
    }
  } catch (updateError) {
    console.error('Failed to record calendar sync status', updateError);
  }
}

export async function runScanForUser(sub: string): Promise<RunScanResult> {
  const [calendarLinkRaw, profile] = await Promise.all([
    loadCalendarLink(sub),
    getUserProfileOnce(sub),
  ]);

  const calendarLink = toCalendarLinkRecord(calendarLinkRaw);
  if (!calendarLink) {
    console.warn('scan-runner: calendar link missing', { sub });
    throw new CalendarLinkMissingError(sub);
  }

  if (calendarLink.status !== 'ACTIVE') {
    console.warn('scan-runner: calendar link not active', { sub, status: calendarLink.status });
    throw new CalendarLinkMissingError(sub, calendarLink.status);
  }

  console.log('scan-runner: starting scan', {
    sub,
    lastSyncedAt: calendarLink.lastSyncedAt,
    lastSyncStatus: calendarLink.lastSyncStatus,
  });
  await clearPendingEncouragements(sub);

  const translationPref = normalizeTranslation(
    (profile?.translationPreference as string | undefined) ?? 'ESV',
  );

  const result = await executeScanPipeline({
    sub,
    calendarLink,
    profile: (profile ?? null) as UserProfilePayload | null,
    translation: translationPref,
  });

  await persistEncouragement(sub, result.encouragement);
  await recordScan(sub, result.log);

  console.log('scan-runner: finished scan', {
    sub,
    encouragementId: result.encouragement.id,
    status: result.log.status,
    stressfulCount: result.log.stressfulCount,
    candidateCount: result.log.candidateCount,
  });
  return {
    encouragementId: result.encouragement.id,
    status: result.log.status,
    log: result.log,
  };
}

interface CalendarLinkRecord {
  calendarUrl: string;
  status: CalendarLinkStatus;
  lastSyncedAt?: string;
  lastSyncStatus?: 'SUCCESS' | 'ERROR';
}

async function loadCalendarLink(sub: string) {
  const candidateKeys: Array<Record<string, string>> = [
    { pk: `USER#${sub}`, sk: 'CALENDAR_LINK' },
    { PK: `USER#${sub}`, SK: 'CALENDAR_LINK' },
  ];

  for (const key of candidateKeys) {
    const result = await dynamo.send(
      new GetCommand({
        TableName: TABLE_NAME,
        Key: key,
        ConsistentRead: true,
      }),
    );

    if (result.Item) {
      console.log('scan-runner: loadCalendarLink', {
        sub,
        table: TABLE_NAME,
        keyVariant: Object.keys(key).join(','),
      });
      return result.Item;
    }
  }

  console.warn('scan-runner: loadCalendarLink not found', {
    sub,
    table: TABLE_NAME,
  });
  return null;
}


function toCalendarLinkRecord(raw: any): CalendarLinkRecord | null {
  if (!raw) return null;

  const calendarUrl = typeof raw.calendarUrl === 'string' ? raw.calendarUrl.trim() : undefined;
  if (!calendarUrl) {
    return null;
  }

  const status = normalizeCalendarStatus(raw.status);

  return {
    calendarUrl,
    status,
    lastSyncedAt: typeof raw.lastSyncedAt === 'string' ? raw.lastSyncedAt : undefined,
    lastSyncStatus: raw.lastSyncStatus === 'SUCCESS' || raw.lastSyncStatus === 'ERROR' ? raw.lastSyncStatus : undefined,
  };
}

function normalizeCalendarStatus(value: any): CalendarLinkStatus {
  const normalized = typeof value === 'string' ? value.toUpperCase() : '';
  switch (normalized) {
    case 'ACTIVE':
    case 'PENDING':
    case 'ERROR':
    case 'MIGRATION_REQUIRED':
      return normalized;
    default:
      return 'PENDING';
  }
}

async function clearPendingEncouragements(sub: string) {
  const result = await dynamo.send(
    new QueryCommand({
      TableName: TABLE_NAME,
      KeyConditionExpression: 'pk = :pk AND begins_with(sk, :prefix)',
      ExpressionAttributeValues: {
        ':pk': `USER#${sub}`,
        ':prefix': 'PENDING#',
      },
    }),
  );

  const now = nowIso();

  const items = (result.Items ?? []) as Array<{ pk: string; sk: string }>;

  await Promise.all(
    items.map(({ pk, sk }) =>
      dynamo.send(
        new UpdateCommand({
          TableName: TABLE_NAME,
          Key: { pk, sk },
          UpdateExpression: 'SET delivered = :true, deliveredAt = :at',
          ExpressionAttributeValues: {
            ':true': true,
            ':at': now,
          },
        }),
      ),
    ),
  );
}

async function persistEncouragement(
  sub: string,
  encouragement: ReturnType<typeof finalizeEncouragement>,
) {
  await dynamo.send(
    new PutCommand({
      TableName: TABLE_NAME,
      Item: {
        pk: `USER#${sub}`,
        sk: `PENDING#${encouragement.id}`,
        id: encouragement.id,
        ref: encouragement.ref,
        text: encouragement.text,
        encouragement: encouragement.encouragement,
        translation: encouragement.translation,
        createdAt: encouragement.createdAt,
        expiresAt: encouragement.expiresAtEpoch,
        expiresAtIso: encouragement.expiresAtIso,
        delivered: false,
      },
    }),
  );
}

async function recordScan(sub: string, log: ScanLog) {
  const createdAt = nowIso();

  await dynamo.send(
    new PutCommand({
      TableName: TABLE_NAME,
      Item: {
        pk: `USER#${sub}`,
        sk: `SCAN#${createdAt}`,
        createdAt,
        ...log,
      },
    }),
  );
}

function normalizeTranslation(value: string): Translation {
  const upper = (value || 'ESV').toUpperCase();
  const allowed: Translation[] = ['ESV', 'KJV', 'NIV', 'NKJV', 'NASB', 'CSB', 'NLT'];
  return allowed.includes(upper as Translation) ? (upper as Translation) : 'ESV';
}

function finalizeEncouragement(ref: string, text: string, encouragement: string, translation: string) {
  const createdAt = nowIso();
  const expiresAtEpoch = futureEpochSeconds(12);
  const expiresAtIso = new Date(expiresAtEpoch * 1000).toISOString();

  return {
    id: randomUUID(),
    ref,
    text,
    encouragement,
    translation,
    createdAt,
    expiresAtEpoch,
    expiresAtIso,
  };
}

interface ScanPipelineParams {
  sub: string;
  calendarLink: CalendarLinkRecord;
  profile: UserProfilePayload | null;
  translation: Translation;
}

export interface ScanLog {
  encouragementId: string;
  status: ScanStatus;
  plannerCount: number;
  stressfulCount: number;
  candidateCount: number;
  translation: Translation;
  tags: string[];
  errorMessage?: string;
}

const BASE_FALLBACK_OPTIONS = [
  {
    ref: 'Philippians 4:6-7',
    text:
      'Do not be anxious about anything, but in everything by prayer and supplication with thanksgiving let your requests be made known to God.',
    encouragement:
      'God invites you to bring today’s stress to Him—take a pause, breathe, and ask for His peace.',
  },
  {
    ref: 'Isaiah 41:10',
    text:
      'Fear not, for I am with you; be not dismayed, for I am your God; I will strengthen you, I will help you, I will uphold you with my righteous right hand.',
    encouragement:
      'You are not facing today alone—lean on God’s strength and let Him hold you steady.',
  },
  {
    ref: 'Psalm 55:22',
    text:
      'Cast your burden on the Lord, and he will sustain you; he will never permit the righteous to be moved.',
    encouragement:
      'Lay every burden down in prayer and trust that God will carry what feels too heavy.',
  },
  {
    ref: 'Matthew 11:28-29',
    text:
      'Come to me, all who labor and are heavy laden, and I will give you rest. Take my yoke upon you, and learn from me, for I am gentle and lowly in heart, and you will find rest for your souls.',
    encouragement:
      'When your schedule feels relentless, rest in Jesus—He is gentle and ready to refresh your soul.',
  },
  {
    ref: '2 Timothy 1:7',
    text:
      'For God gave us a spirit not of fear but of power and love and self-control.',
    encouragement:
      'Step into today with courage—God equips you with a spirit of power, love, and a clear mind.',
  },
];

const DEFAULT_EXCLUDED_REFS = ['Philippians 4:6-7'];

function normalizeReference(ref: string | undefined): string {
  return (ref ?? '').replace(/\s+/g, ' ').trim().toLowerCase();
}

function parseExcludedRefs(): Set<string> {
  const raw = process.env.SCAN_EXCLUDED_VERSES;
  let values: string[] = DEFAULT_EXCLUDED_REFS;

  if (raw && raw.length > 0) {
    try {
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed)) {
        values = parsed.filter((entry): entry is string => typeof entry === 'string');
      } else if (typeof parsed === 'string') {
        values = [parsed];
      }
    } catch {
      values = raw.split(',').map((part) => part.trim()).filter(Boolean);
    }
  }

  const normalized = values
    .map((entry) => normalizeReference(entry))
    .filter((entry) => entry.length > 0);

  return new Set(normalized);
}

function excludeVerses<T extends { ref: string }>(items: T[], excluded: Set<string>): T[] {
  if (excluded.size === 0) {
    return items;
  }

  return items.filter((item) => !excluded.has(normalizeReference(item.ref)));
}

const EXCLUDED_REFS = parseExcludedRefs();

interface CalendarAgendaEntry {
  id: string;
  title: string;
  kind: CalendarEventItem['kind'];
  startAt?: string | null;
  endAt?: string | null;
  dueAt?: string | null;
  course?: string | null;
  location?: string | null;
  url?: string | null;
  timeZoneId?: string | null;
}

async function executeScanPipeline(
  params: ScanPipelineParams,
): Promise<{ encouragement: ReturnType<typeof finalizeEncouragement>; log: ScanLog }> {
  const { sub, calendarLink, profile, translation } = params;
  const mcp = bibleMcpFromEnv();
  let calendarEvents: CalendarEventItem[] = [];
  let stressfulItems: StressfulItem[] = [];
  let verseCandidates: VerseCandidate[] = [];

  try {
    calendarEvents = await fetchCalendarEvents({
      calendarUrl: calendarLink.calendarUrl,
      windowDays: 14,
    });
    console.log('scan-runner: fetched calendar events', {
      sub,
      eventCount: calendarEvents.length,
    });

    stressfulItems = mapCalendarEventsToStressfulItems(calendarEvents, {
      translation,
      maxItems: 25,
    });
    console.log('scan-runner: mapped stressful items', {
      sub,
      stressfulCount: stressfulItems.length,
    });

    verseCandidates = await buildVerseCandidates(mcp, stressfulItems, translation);
    verseCandidates = excludeVerses(verseCandidates, EXCLUDED_REFS);
    console.log('scan-runner: built verse candidates', {
      sub,
      candidateCount: verseCandidates.length,
    });

    const uniqueTags = Array.from(
      new Set(
        stressfulItems
          .flatMap((item) => item.stressTags ?? [])
          .map((tag) => tag.toLowerCase()),
      ),
    );

    await recordCalendarSyncStatus(sub, 'SUCCESS');
    await persistCalendarSnapshot(sub, calendarEvents);

    if (verseCandidates.length === 0) {
      console.warn('scan-runner: no verse candidates, using fallback', {
        sub,
        stressfulCount: stressfulItems.length,
      });
      return buildFallbackResult({
        translation,
        plannerCount: calendarEvents.length,
        stressfulCount: stressfulItems.length,
        candidateCount: 0,
        tags: uniqueTags,
        reason: 'No verse candidates from MCP',
      });
    }

    const agentResult = await runVerseSelectionAgent({
      profile,
      stressfulItems,
      verseCandidates,
      translationPreference: translation,
    });

    const encouragement = finalizeEncouragement(
      agentResult.ref,
      agentResult.text,
      agentResult.encouragement,
      agentResult.translation,
    );

    return {
      encouragement,
      log: {
        encouragementId: encouragement.id,
        status: 'SUCCESS',
        plannerCount: calendarEvents.length,
        stressfulCount: stressfulItems.length,
        candidateCount: verseCandidates.length,
        translation,
        tags: uniqueTags,
      },
    };
  } catch (error) {
    console.error('Scan pipeline error', error);

    const uniqueTags = Array.from(
      new Set(
        stressfulItems
          .flatMap((item) => item.stressTags ?? [])
          .map((tag) => tag.toLowerCase()),
      ),
    );

    await recordCalendarSyncStatus(
      sub,
      'ERROR',
      error instanceof Error ? error.message : 'Unknown error',
    );
    if (calendarEvents.length > 0) {
      try {
        await persistCalendarSnapshot(sub, calendarEvents);
      } catch (persistError) {
        console.error('scan-runner: failed to persist snapshot after error', persistError);
      }
    }
    console.warn('scan-runner: falling back after pipeline error', {
      sub,
      error: error instanceof Error ? error.message : String(error),
      stressfulCount: stressfulItems.length,
      candidateCount: verseCandidates.length,
    });

    return buildFallbackResult({
      translation,
      plannerCount: calendarEvents.length,
      stressfulCount: stressfulItems.length,
      candidateCount: verseCandidates.length,
      tags: uniqueTags,
      reason: error instanceof Error ? error.message : 'Unknown error',
    });
  }
}

async function persistCalendarSnapshot(sub: string, events: CalendarEventItem[]) {
  const now = nowIso();
  const sorted = [...events]
    .sort((a, b) => {
      const aTime = Date.parse(a.dueAt ?? a.startAt ?? a.endAt ?? '');
      const bTime = Date.parse(b.dueAt ?? b.startAt ?? b.endAt ?? '');
      if (Number.isNaN(aTime) && Number.isNaN(bTime)) return 0;
      if (Number.isNaN(aTime)) return 1;
      if (Number.isNaN(bTime)) return -1;
      return aTime - bTime;
    })
    .slice(0, 40);

  const items: CalendarAgendaEntry[] = sorted.map((event) => ({
    id: event.id,
    title: event.title ?? event.summary ?? 'Calendar item',
    kind: event.kind,
    startAt: event.startAt ?? null,
    endAt: event.endAt ?? null,
    dueAt: event.dueAt ?? null,
    course: event.course ?? null,
    location: event.location ?? null,
    url: event.url ?? null,
    timeZoneId: event.timeZoneId ?? null,
  }));

  await dynamo.send(
    new PutCommand({
      TableName: TABLE_NAME,
      Item: {
        pk: `USER#${sub}`,
        sk: 'CALENDAR_SNAPSHOT',
        PK: `USER#${sub}`,
        SK: 'CALENDAR_SNAPSHOT',
        fetchedAt: now,
        items,
      },
    }),
  );
}

function pickFallbackEncouragement(translation: Translation) {
  const options = excludeVerses(BASE_FALLBACK_OPTIONS, EXCLUDED_REFS);
  const pool = options.length > 0 ? options : BASE_FALLBACK_OPTIONS;
  const choice = pool[Math.floor(Math.random() * pool.length)];
  return finalizeEncouragement(choice.ref, choice.text, choice.encouragement, translation);
}

function buildFallbackResult(args: {
  translation: Translation;
  plannerCount: number;
  stressfulCount: number;
  candidateCount: number;
  tags: string[];
  reason?: string;
}): { encouragement: ReturnType<typeof finalizeEncouragement>; log: ScanLog } {
  const encouragement = pickFallbackEncouragement(args.translation);

  return {
    encouragement,
    log: {
      encouragementId: encouragement.id,
      status: 'FALLBACK',
      plannerCount: args.plannerCount,
      stressfulCount: args.stressfulCount,
      candidateCount: args.candidateCount,
      translation: args.translation,
      tags: args.tags,
      errorMessage: args.reason,
    },
  };
}
