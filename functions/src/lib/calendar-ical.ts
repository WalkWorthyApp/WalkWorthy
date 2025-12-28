export type CalendarEventKind = 'assignment' | 'exam' | 'event';

export interface CalendarEventItem {
  id: string;
  title: string;
  summary: string;
  course?: string;
  startAt?: string;
  endAt?: string;
  dueAt?: string;
  isAllDay: boolean;
  location?: string;
  description?: string;
  url?: string;
  categories?: string[];
  kind: CalendarEventKind;
  timeZoneId?: string;
}

interface FetchOptions {
  calendarUrl: string;
  windowDays?: number;
  now?: Date;
}

const DEFAULT_WINDOW_DAYS = 14;
const EXAM_RE = /\b(exam|midterm|final|quiz|test)\b/i;
const ASSIGNMENT_RE = /\b(assign|homework|paper|project|essay|lab|due)\b/i;

/**
 * Validate calendar URL to prevent SSRF attacks.
 * Only allows HTTPS URLs that don't point to internal/private IP ranges.
 *
 * @param url - The calendar URL to validate
 * @returns True if URL is safe to fetch
 */
function isValidCalendarUrl(url: string): boolean {
  try {
    const parsed = new URL(url);

    // Normalize hostname for consistent checking
    const hostname = parsed.hostname.toLowerCase();

    // Only allow HTTPS (or HTTP for localhost during development)
    if (parsed.protocol !== 'https:' &&
        !(parsed.protocol === 'http:' && (hostname === 'localhost' || hostname === '127.0.0.1'))) {
      return false;
    }

    // Block internal/private IP ranges to prevent SSRF
    // Note: localhost and 127.0.0.1 are allowed for development (gated by protocol check above)
    if (hostname === '0.0.0.0' ||
        hostname.startsWith('169.254.') || // Link-local
        hostname.startsWith('10.') ||      // Private class A
        hostname.startsWith('172.16.') ||  // Private class B (172.16.0.0 - 172.31.255.255)
        hostname.startsWith('172.17.') ||
        hostname.startsWith('172.18.') ||
        hostname.startsWith('172.19.') ||
        hostname.startsWith('172.2') ||
        hostname.startsWith('172.30.') ||
        hostname.startsWith('172.31.') ||
        hostname.startsWith('192.168.'))   // Private class C
    {
      return false;
    }

    return true;
  } catch {
    return false;
  }
}

export async function fetchCalendarEvents(options: FetchOptions): Promise<CalendarEventItem[]> {
  const { calendarUrl } = options;

  if (!isValidCalendarUrl(calendarUrl)) {
    throw new Error('Invalid calendar URL: must be HTTPS and not point to internal resources');
  }

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
      const aTime = Date.parse(a.dueAt ?? a.startAt ?? a.endAt ?? '');
      const bTime = Date.parse(b.dueAt ?? b.startAt ?? b.endAt ?? '');
      if (Number.isNaN(aTime) && Number.isNaN(bTime)) return 0;
      if (Number.isNaN(aTime)) return 1;
      if (Number.isNaN(bTime)) return -1;
      return aTime - bTime;
    });
  } catch (error) {
    if (error instanceof Error && error.name === 'AbortError') {
      throw new Error(`Calendar fetch timed out after 12 seconds for URL: ${calendarUrl}`);
    }
    if (error instanceof TypeError) {
      throw new Error(`Network error fetching calendar: ${error.message}`);
    }
    throw error;
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
  let dueIso: string | undefined;
  let startTimeZone: string | undefined;
  let endTimeZone: string | undefined;
  let dueTimeZone: string | undefined;
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
        if (parsedDate?.timeZoneId) {
          startTimeZone = parsedDate.timeZoneId;
        }
        break;
      }
      case 'DTEND': {
        const parsedDate = parseDateTime(value, params);
        endIso = parsedDate?.iso;
        if (parsedDate?.isDateOnly) {
          isAllDay = true;
        }
        if (parsedDate?.timeZoneId) {
          endTimeZone = parsedDate.timeZoneId;
        }
        break;
      }
      case 'DUE': {
        const parsedDate = parseDateTime(value, params);
        dueIso = parsedDate?.iso;
        if (parsedDate?.isDateOnly) {
          isAllDay = true;
        }
        if (parsedDate?.timeZoneId) {
          dueTimeZone = parsedDate.timeZoneId;
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

  if (!startIso && !endIso && !dueIso) {
    return null;
  }

  const startDate = startIso
    ? new Date(startIso)
    : dueIso
      ? new Date(dueIso)
      : undefined;
  const endDate = endIso
    ? new Date(endIso)
    : dueIso
      ? new Date(dueIso)
      : undefined;

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
    dueAt: dueIso,
    isAllDay,
    location,
    description,
    url,
    categories: normalizedCategories.length > 0 ? normalizedCategories : undefined,
    kind: eventKind,
    timeZoneId: dueTimeZone ?? startTimeZone ?? endTimeZone,
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
  // Use a unique placeholder to preserve literal backslashes during escape processing.
  // Process escaped backslashes first to prevent sequences like "\\n" (literal backslash + n)
  // from being misinterpreted as escaped newline "\n".
  const BACKSLASH_PLACEHOLDER = '\u0000__BS__\u0000';
  return value
    .replace(/\\\\/g, BACKSLASH_PLACEHOLDER)  // Escaped backslash -> placeholder
    .replace(/\\n/gi, '\n')                    // Escaped newline
    .replace(/\\t/gi, '\t')                    // Escaped tab
    .replace(/\\,/g, ',')                      // Escaped comma
    .replace(/\\;/g, ';')                      // Escaped semicolon
    .replace(new RegExp(BACKSLASH_PLACEHOLDER.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g'), '\\'); // Placeholder -> single backslash
}

/**
 * Formats date/time components as a naive (timezone-agnostic) ISO string.
 * Floating times are stored as-is without UTC conversion or Z suffix.
 * Consumers must interpret these values as local/naive and apply timezone context as needed.
 */
function formatFloatingDateTime(
  year: number,
  month: number,
  day: number,
  hour?: number,
  minute?: number,
  second?: number,
): string {
  const pad = (n: number) => String(n).padStart(2, '0');
  const datePart = `${year}-${pad(month)}-${pad(day)}`;
  if (hour === undefined) {
    return datePart; // Date-only: YYYY-MM-DD
  }
  // Date-time: YYYY-MM-DDTHH:MM:SS (no Z suffix)
  return `${datePart}T${pad(hour)}:${pad(minute!)}:${pad(second!)}`;
}

function parseDateTime(
  value: string,
  params: Record<string, string>,
): { iso: string; isDateOnly: boolean; timeZoneId?: string } | undefined {
  const trimmed = value.trim();
  const upper = trimmed.toUpperCase();
  const timeZone = resolveTimeZone(params.TZID);

  const isDateOnly = params.VALUE?.toUpperCase() === 'DATE' || /^[0-9]{8}$/.test(upper);
  if (isDateOnly) {
    const match = upper.match(/^(\d{4})(\d{2})(\d{2})$/);
    if (!match) return undefined;
    const year = Number(match[1]);
    const month = Number(match[2]);
    const day = Number(match[3]);
    // Floating date-only values are stored as naive YYYY-MM-DD without Z
    const iso = formatFloatingDateTime(year, month, day);
    return { iso, isDateOnly: true, timeZoneId: timeZone ?? 'floating' };
  }

  const zuluMatch = upper.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/);
  if (zuluMatch) {
    return {
      iso: `${zuluMatch[1]}-${zuluMatch[2]}-${zuluMatch[3]}T${zuluMatch[4]}:${zuluMatch[5]}:${zuluMatch[6]}Z`,
      isDateOnly: false,
      timeZoneId: 'UTC',
    };
  }

  const localMatch = upper.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})$/);
  if (localMatch) {
    const year = Number(localMatch[1]);
    const month = Number(localMatch[2]);
    const day = Number(localMatch[3]);
    const hour = Number(localMatch[4]);
    const minute = Number(localMatch[5]);
    const second = Number(localMatch[6]);
    if (timeZone) {
      const utcDate = convertToUTCFromTimeZone(
        { year, month: month - 1, day, hour, minute, second },
        timeZone,
      );
      if (utcDate) {
        return { iso: utcDate.toISOString(), isDateOnly: false, timeZoneId: timeZone };
      }
    }
    // Floating times (no TZID, no Z) are stored as naive YYYY-MM-DDTHH:MM:SS without Z suffix
    const iso = formatFloatingDateTime(year, month, day, hour, minute, second);
    return { iso, isDateOnly: false, timeZoneId: 'floating' };
  }

  const parsed = new Date(trimmed);
  if (!Number.isNaN(parsed.getTime())) {
    return { iso: parsed.toISOString(), isDateOnly: false };
  }

  return undefined;
}

function resolveTimeZone(raw?: string): string | undefined {
  if (!raw) return undefined;
  const trimmed = raw.replace(/^"|"$/g, '').trim();
  if (!trimmed) return undefined;
  if (trimmed.startsWith('/')) {
    const parts = trimmed.split('/').filter(Boolean);
    if (parts.length === 0) {
      return undefined;
    }
    if (parts.length > 1 && parts[0].includes('.')) {
      return parts.slice(1).join('/');
    }
    return parts.join('/');
  }
  return trimmed;
}

function convertToUTCFromTimeZone(
  components: {
    year: number;
    month: number;
    day: number;
    hour: number;
    minute: number;
    second: number;
  },
  timeZone: string,
): Date | undefined {
  const { year, month, day, hour, minute, second } = components;
  const tentativeUtc = new Date(Date.UTC(year, month, day, hour, minute, second));
  const offset = getTimeZoneOffsetMilliseconds(timeZone, tentativeUtc);
  if (offset === undefined) {
    return undefined;
  }
  return new Date(tentativeUtc.getTime() - offset);
}

function getTimeZoneOffsetMilliseconds(timeZone: string, date: Date): number | undefined {
  try {
    const dtf = new Intl.DateTimeFormat('en-US', {
      timeZone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hour12: false,
    });

    const parts = dtf.formatToParts(date);
    const map: Record<string, number> = {};
    for (const part of parts) {
      if (part.type === 'literal') continue;
      const num = Number(part.value);
      if (!Number.isNaN(num)) {
        map[part.type] = num;
      }
    }

    const asIf = Date.UTC(
      map.year ?? date.getUTCFullYear(),
      (map.month ?? date.getUTCMonth() + 1) - 1,
      map.day ?? date.getUTCDate(),
      map.hour ?? date.getUTCHours(),
      map.minute ?? date.getUTCMinutes(),
      map.second ?? date.getUTCSeconds(),
    );

    return asIf - date.getTime();
  } catch (error) {
    console.warn('calendar-ical: failed to resolve timezone offset', { timeZone, error });
    return undefined;
  }
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
