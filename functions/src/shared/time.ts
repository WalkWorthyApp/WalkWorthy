import { getUserProfileOnce } from './profile';

export function nowIso(): string {
  return new Date().toISOString();
}

export function futureEpochSeconds(hoursFromNow: number): number {
  const now = Date.now();
  const msAhead = hoursFromNow * 60 * 60 * 1000;
  return Math.floor((now + msAhead) / 1000);
}

/**
 * Format a given date as YYYY-MM-DD in the specified timezone. Falls back to
 * UTC when timezone is missing or invalid. Uses en-CA to get ISO ordering
 * (YYYY-MM-DD) directly from Intl.DateTimeFormat.
 */
export function getDateStringInTimezone(date: Date, timezone?: string): string {
  if (timezone) {
    try {
      const formatter = new Intl.DateTimeFormat('en-CA', {
        timeZone: timezone,
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
      });
      return formatter.format(date);
    } catch {
      // Fall back to UTC if timezone is invalid
    }
  }
  return date.toISOString().split('T')[0];
}

/**
 * Compute the user's logical day string (YYYY-MM-DD) in their own timezone.
 * Hours 0–2 still belong to the previous logical day so the app's morning/
 * midday/evening buckets align with a human-intuitive "day".
 *
 * This is the single source of truth for logical-date bucketing across every
 * endpoint — summaries written under the user's local date would never match
 * queries that bucket by UTC, so all call sites must import from here.
 */
export function getLogicalDateString(timezone?: string): string {
  const now = new Date();
  let hour: number;
  try {
    if (timezone) {
      const fmt = new Intl.DateTimeFormat('en-US', {
        timeZone: timezone,
        hour: 'numeric',
        hourCycle: 'h23',
      });
      hour = parseInt(fmt.format(now), 10);
    } else {
      hour = now.getUTCHours();
    }
  } catch {
    hour = now.getUTCHours();
  }
  const logicalNow = hour < 3 ? new Date(now.getTime() - 24 * 60 * 60 * 1000) : now;
  return getDateStringInTimezone(logicalNow, timezone);
}

/**
 * Shift a logical date string by `deltaDays`, keeping the result in the same
 * YYYY-MM-DD format. Days are calendar days — no DST shenanigans because the
 * math runs on the anchor ISO string's midnight UTC.
 */
export function shiftLogicalDate(dateString: string, deltaDays: number): string {
  const anchor = new Date(`${dateString}T00:00:00Z`);
  anchor.setUTCDate(anchor.getUTCDate() + deltaDays);
  return anchor.toISOString().split('T')[0];
}

/**
 * Load the user's profile and return today's logical date string in the
 * user's timezone. Falls back to `America/New_York` when the profile has no
 * timezone, matching the behavior in api/mood-checkin.ts.
 */
export async function getUserLogicalDate(userId: string): Promise<string> {
  const profile = await getUserProfileOnce(userId);
  const tz = profile?.timezone || 'America/New_York';
  return getLogicalDateString(tz);
}
