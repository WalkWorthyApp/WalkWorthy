import type { APIGatewayProxyEventV2 } from 'aws-lambda';
import { GetCommand } from '@aws-sdk/lib-dynamodb';

import { getUserSub } from '../shared/auth';
import { json, unauthorized } from '../shared/http';
import { dynamo } from '../shared/dynamo';
import { TABLE_NAME } from '../shared/env';

interface CalendarAgendaEntry {
  id: string;
  title: string;
  kind: 'assignment' | 'exam' | 'event';
  startAt?: string | null;
  endAt?: string | null;
  dueAt?: string | null;
  course?: string | null;
  location?: string | null;
  url?: string | null;
  timeZoneId?: string | null;
}

interface CalendarAgendaResponse {
  fetchedAt?: string;
  items: CalendarAgendaEntry[];
}

const SNAPSHOT_SK = 'CALENDAR_SNAPSHOT';

export async function handler(event: APIGatewayProxyEventV2) {
  const sub = getUserSub(event);
  if (!sub) {
    return unauthorized();
  }

  const snapshot = await loadSnapshot(sub);
  const response: CalendarAgendaResponse = snapshot ?? { items: [] };
  return json(200, response);
}

async function loadSnapshot(sub: string): Promise<CalendarAgendaResponse | null> {
  const candidateKeys: Array<Record<string, string>> = [
    { pk: `USER#${sub}`, sk: SNAPSHOT_SK },
    { PK: `USER#${sub}`, SK: SNAPSHOT_SK },
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
      return {
        fetchedAt: typeof result.Item.fetchedAt === 'string' ? result.Item.fetchedAt : undefined,
        items: Array.isArray(result.Item.items)
          ? (result.Item.items as CalendarAgendaEntry[])
          : [],
      };
    }
  }

  return null;
}
