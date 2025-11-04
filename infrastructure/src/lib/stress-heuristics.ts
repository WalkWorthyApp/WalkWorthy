import { Translation, StressfulItem, VerseCandidate } from './walkworthy-agent';
import type { CalendarEventItem } from './calendar-ical';
import { BibleMcpProvider } from './bibleMcp';

interface HeuristicOptions {
  translation: Translation;
  maxItems?: number;
  maxTags?: number;
}

const DEFAULT_TAGS = ['anxiety', 'stress', 'rest', 'peace'];
const GROUP_RE = /\bgroup\b/i;

export function mapCalendarEventsToStressfulItems(
  items: CalendarEventItem[],
  options: HeuristicOptions,
): StressfulItem[] {
  const mapped = items
    .map((item) => calendarEventToStressfulItem(item, options))
    .filter((item): item is StressfulItem => Boolean(item));
  return mapped.slice(0, options.maxItems ?? 20);
}

export async function buildVerseCandidates(
  mcp: BibleMcpProvider,
  stressfulItems: StressfulItem[],
  translation: Translation,
): Promise<VerseCandidate[]> {

  const tagCounts = new Map<string, number>();
  for (const item of stressfulItems) {
    for (const tag of item.stressTags ?? []) {
      const normalized = tag.toLowerCase();
      tagCounts.set(normalized, (tagCounts.get(normalized) ?? 0) + 1);
    }
  }

  for (const fallback of DEFAULT_TAGS) {
    if (!tagCounts.has(fallback)) {
      tagCounts.set(fallback, 1);
    }
  }

  const rankedTags = Array.from(tagCounts.entries())
    .sort((a, b) => b[1] - a[1])
    .slice(0, 4)
    .map(([tag]) => tag);

  const verses: VerseCandidate[] = [];
  const seen = new Set<string>();

  for (const tag of rankedTags) {
    try {
      const found = await mcp.searchByKeywords([tag], translation, 5);
      for (const candidate of found) {
        const key = candidate.ref.toLowerCase();
        if (seen.has(key)) continue;
        seen.add(key);
        verses.push({
          ref: candidate.ref,
          text: candidate.text,
          translation: candidate.translation,
        });
      }
    } catch (error) {
      console.warn('MCP search failed for tag', tag, error);
    }
    if (verses.length >= 8) break;
  }

  return verses.slice(0, 8);
}

function calendarEventToStressfulItem(
  item: CalendarEventItem,
  options: HeuristicOptions,
): StressfulItem | null {
  const title = (item.title ?? item.summary ?? '').trim();
  if (!title) {
    return null;
  }

  const dueIso = item.startAt ?? item.endAt;
  const dueDate = dueIso ? new Date(dueIso) : undefined;
  const now = new Date();
  const hoursUntilDue = dueDate ? (dueDate.getTime() - now.getTime()) / (1000 * 60 * 60) : undefined;

  const tags = new Set<string>();
  tags.add('encouragement');
  tags.add('calendar');
  tags.add(item.kind);

  if (item.kind === 'exam') {
    tags.add('exam');
    tags.add('courage');
  }

  if (item.kind === 'assignment') {
    tags.add('assignment');
  }

  if (item.course) {
    tags.add('course');
  }

  if (item.isAllDay) {
    tags.add('all-day');
  }

  if (hoursUntilDue !== undefined) {
    if (hoursUntilDue <= 48) tags.add('deadline');
    if (hoursUntilDue <= 6) tags.add('urgency');
    if (hoursUntilDue < 0) tags.add('overdue');
  }

  if (item.description && GROUP_RE.test(item.description)) {
    tags.add('community');
  }

  for (const category of item.categories ?? []) {
    const normalized = category.trim().toLowerCase();
    if (!normalized) continue;
    tags.add(normalized);
  }

  const stressTags = Array.from(tags).slice(0, options.maxTags ?? 6);

  return {
    type: item.kind,
    title,
    course: item.course,
    dueAt: dueDate ? dueDate.toISOString() : undefined,
    stressTags,
    weight: undefined,
  };
}
