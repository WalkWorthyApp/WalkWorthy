export type CalendarEventKind = 'assignment' | 'exam' | 'event';

export interface CalendarEventItem {
  id: string;
  title: string;
  summary: string;
  course?: string;
  startAt?: string;
  endAt?: string;
  isAllDay: boolean;
  location?: string;
  description?: string;
  url?: string;
  categories?: string[];
  kind: CalendarEventKind;
}

interface FetchOptions {
  calendarUrl: string;
  windowDays?: number;
  now?: Date;
}

const DEFAULT_WINDOW_DAYS = 14;
const EXAM_RE = /\b(exam|midterm|final|quiz|test)\b/i;
const ASSIGNMENT_RE = /\b(assign|homework|paper|project|essay|lab|due)\b/i;

export async function fetchCalendarEvents(options: FetchOptions): Promise<CalendarEventItem[]> {
  const { calendarUrl } = options;
  const windowDays = options.windowDays ?? DEFAULT_WINDOW_DAYS;
  const now = options.now ?? new Date();
  const rangeEnd = new Date(now.getTime() + windowDays * 24 * 60 * 60 * 1000);

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12_000);

  try {
    const response = await fetch(calendarUrl, {
      headers: {
        'User-Agent': 'WalkWorthy/1.0 (+https://walkworthy.app)',
        'Cache-Control': 'no-cache',
      },
      signal: controller.signal,
    });

    if (!response.ok) {
      throw new Error(`Calendar fetch failed with status ${response.status}`);
    }

    const body = await response.text();
    if (!body.includes('BEGIN:VCALENDAR')) {
      throw new Error('Response is not a valid iCal feed');
    }

    const lines = unfoldLines(body);
    const events: CalendarEventItem[] = [];
    const seen = new Set<string>();

    let collecting = false;
    let nestedDepth = 0;
    let eventLines: string[] = [];

    for (const rawLine of lines) {
      const upper = rawLine.trim().toUpperCase();

      if (!collecting) {
        if (upper === 'BEGIN:VEVENT') {
          collecting = true;
          nestedDepth = 0;
          eventLines = [];
        }
        continue;
      }

      if (upper.startsWith('BEGIN:') && upper !== 'BEGIN:VEVENT') {
        nestedDepth += 1;
        continue;
      }

      if (upper.startsWith('END:') && upper !== 'END:VEVENT') {
        if (nestedDepth > 0) {
          nestedDepth -= 1;
        }
        continue;
      }

      if (upper === 'END:VEVENT' && nestedDepth === 0) {
        const event = parseEventLines(eventLines, now, rangeEnd);
        if (event && !seen.has(event.id)) {
          seen.add(event.id);
          events.push(event);
        }
        collecting = false;
        continue;
      }

      if (nestedDepth > 0) {
        continue;
      }

      eventLines.push(rawLine);
    }

    return events.sort((a, b) => {
      const aTime = a.startAt ? Date.parse(a.startAt) : Number.MAX_SAFE_INTEGER;
      const bTime = b.startAt ? Date.parse(b.startAt) : Number.MAX_SAFE_INTEGER;
      return aTime - bTime;
    });
  } finally {
    clearTimeout(timeout);
  }
}

function unfoldLines(source: string): string[] {
  const rawLines = source.split(/\r?\n/);
  const unfolded: string[] = [];

  for (const line of rawLines) {
    if (line.startsWith(' ') || line.startsWith('\t')) {
      if (unfolded.length === 0) {
        unfolded.push(line.trimStart());
      } else {
        unfolded[unfolded.length - 1] += line.slice(1);
      }
    } else {
      unfolded.push(line);
    }
  }

  return unfolded;
}

function parseEventLines(
  lines: string[],
  windowStart: Date,
  windowEnd: Date,
): CalendarEventItem | null {
  let uid: string | undefined;
  let summary: string | undefined;
  let description: string | undefined;
  let location: string | undefined;
  let url: string | undefined;
  const categories: string[] = [];

  let startIso: string | undefined;
  let endIso: string | undefined;
  let isAllDay = false;

  for (const line of lines) {
    const parsed = parseProperty(line);
    if (!parsed) continue;

    const { name, value, params } = parsed;
    switch (name) {
      case 'UID':
        uid = value;
        break;
      case 'SUMMARY':
        summary = value;
        break;
      case 'DESCRIPTION':
        description = value;
        break;
      case 'LOCATION':
        location = value;
        break;
      case 'URL':
      case 'SOURCE':
        url = value;
        break;
      case 'DTSTART': {
        const parsedDate = parseDateTime(value, params);
        startIso = parsedDate?.iso;
        if (parsedDate?.isDateOnly) {
          isAllDay = true;
        }
        break;
      }
      case 'DTEND': {
        const parsedDate = parseDateTime(value, params);
        endIso = parsedDate?.iso;
        if (parsedDate?.isDateOnly) {
          isAllDay = true;
        }
        break;
      }
      case 'CATEGORIES': {
        const parts = value.split(',').map((entry) => entry.trim()).filter(Boolean);
        categories.push(...parts);
        break;
      }
      default:
        break;
    }
  }

  if (!startIso && !endIso) {
    return null;
  }

  const startDate = startIso ? new Date(startIso) : undefined;
  const endDate = endIso ? new Date(endIso) : undefined;

  if (!isWithinWindow(startDate, endDate, windowStart, windowEnd)) {
    return null;
  }

  const summaryText = summary ?? '';
  const { title, course } = deriveTitleAndCourse(summaryText);
  const normalizedCategories = Array.from(new Set(categories));
  const eventKind = deriveKind(summaryText, description, normalizedCategories);

  return {
    id: uid ?? `${title}-${startIso ?? endIso ?? Date.now()}`,
    title,
    summary: summaryText || title,
    course,
    startAt: startIso,
    endAt: endIso,
    isAllDay,
    location,
    description,
    url,
    categories: normalizedCategories.length > 0 ? normalizedCategories : undefined,
    kind: eventKind,
  };
}

function parseProperty(line: string): { name: string; value: string; params: Record<string, string> } | null {
  const separator = line.indexOf(':');
  if (separator === -1) {
    return null;
  }

  const namePart = line.slice(0, separator);
  const rawValue = line.slice(separator + 1);

  const segments = namePart.split(';');
  const name = segments[0].trim().toUpperCase();
  const params: Record<string, string> = {};

  for (const segment of segments.slice(1)) {
    const eqIndex = segment.indexOf('=');
    if (eqIndex === -1) continue;
    const key = segment.slice(0, eqIndex).trim().toUpperCase();
    const value = segment.slice(eqIndex + 1).trim();
    if (key) {
      params[key] = value;
    }
  }

  return {
    name,
    value: unescapeICSValue(rawValue.trim()),
    params,
  };
}

function unescapeICSValue(value: string): string {
  return value
    .replace(/\\n/gi, '\n')
    .replace(/\\t/gi, '\t')
    .replace(/\\\\/g, '\\')
    .replace(/\\,/g, ',')
    .replace(/\\;/g, ';');
}

function parseDateTime(
  value: string,
  params: Record<string, string>,
): { iso: string; isDateOnly: boolean } | undefined {
  const trimmed = value.trim();
  const upper = trimmed.toUpperCase();

  const isDateOnly = params.VALUE?.toUpperCase() === 'DATE' || /^[0-9]{8}$/.test(upper);
  if (isDateOnly) {
    const match = upper.match(/^(\d{4})(\d{2})(\d{2})$/);
    if (!match) return undefined;
    const year = Number(match[1]);
    const month = Number(match[2]) - 1;
    const day = Number(match[3]);
    const date = new Date(Date.UTC(year, month, day));
    return { iso: date.toISOString(), isDateOnly: true };
  }

  const zuluMatch = upper.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/);
  if (zuluMatch) {
    return {
      iso: `${zuluMatch[1]}-${zuluMatch[2]}-${zuluMatch[3]}T${zuluMatch[4]}:${zuluMatch[5]}:${zuluMatch[6]}Z`,
      isDateOnly: false,
    };
  }

  const localMatch = upper.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})$/);
  if (localMatch) {
    const year = Number(localMatch[1]);
    const month = Number(localMatch[2]) - 1;
    const day = Number(localMatch[3]);
    const hour = Number(localMatch[4]);
    const minute = Number(localMatch[5]);
    const second = Number(localMatch[6]);
    const date = new Date(year, month, day, hour, minute, second);
    return { iso: date.toISOString(), isDateOnly: false };
  }

  const parsed = new Date(trimmed);
  if (!Number.isNaN(parsed.getTime())) {
    return { iso: parsed.toISOString(), isDateOnly: false };
  }

  return undefined;
}

function isWithinWindow(start: Date | undefined, end: Date | undefined, windowStart: Date, windowEnd: Date): boolean {
  const startTime = start?.getTime();
  const endTime = end?.getTime();
  const windowStartTime = windowStart.getTime();
  const windowEndTime = windowEnd.getTime();

  if (startTime && endTime) {
    return !(endTime < windowStartTime || startTime > windowEndTime);
  }
  if (startTime) {
    return startTime >= windowStartTime && startTime <= windowEndTime;
  }
  if (endTime) {
    return endTime >= windowStartTime && endTime <= windowEndTime;
  }
  return false;
}

function sanitizedText(value: unknown): string | undefined {
  if (typeof value !== 'string') {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function deriveTitleAndCourse(summary: string | undefined): { title: string; course?: string } {
  if (!summary || summary.length === 0) {
    return { title: 'Canvas event' };
  }

  const colonSplit = summary.split(':');
  if (colonSplit.length >= 2) {
    const course = colonSplit[0]?.trim();
    const title = colonSplit.slice(1).join(':').trim();
    if (course && title) {
      return { title, course };
    }
  }

  const dashSplit = summary.split(' - ');
  if (dashSplit.length >= 2) {
    const course = dashSplit[0]?.trim();
    const title = dashSplit.slice(1).join(' - ').trim();
    if (course && title) {
      return { title, course };
    }
  }

  return { title: summary };
}

function deriveKind(summary?: string, description?: string, categories?: string[]): CalendarEventKind {
  const summaryText = summary ?? '';
  const descriptionText = description ?? '';
  const combined = `${summaryText}\n${descriptionText}\n${(categories ?? []).join(' ')}`;

  if (EXAM_RE.test(combined)) {
    return 'exam';
  }
  if (ASSIGNMENT_RE.test(combined)) {
    return 'assignment';
  }
  return 'event';
}
