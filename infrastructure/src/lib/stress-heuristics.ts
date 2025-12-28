import { Translation, StressfulItem } from './walkworthy-agent';
import type { CalendarEventItem } from './calendar-ical';

interface HeuristicOptions {
  translation: Translation;
  maxItems?: number;
  maxTags?: number;
}

const DEFAULT_TAGS = ['anxiety', 'stress', 'rest', 'peace'];
const GROUP_RE = /\bgroup\b/i;
const STOPWORDS = new Set(['the','and','for','with','your','from','that','this','into','about','over','under','into','onto','exam','assignment','event','today','tonight','meeting','class','work']);
const INTERNAL_ONLY_TAGS = new Set(['encouragement', 'calendar', 'event', 'assignment', 'course', 'all-day']);

function extractKeywords(input: string): string[] {
  const words = input.toLowerCase().match(/[a-z0-9']+/g) ?? [];
  const filtered = words
    .filter((word) => word.length > 3 && !STOPWORDS.has(word))
    .slice(0, 5);
  return Array.from(new Set(filtered));
}

export function mapCalendarEventsToStressfulItems(
  items: CalendarEventItem[],
  options: HeuristicOptions,
): StressfulItem[] {
  const mapped = items
    .map((item) => calendarEventToStressfulItem(item, options))
    .filter((item): item is StressfulItem => Boolean(item));
  return mapped.slice(0, options.maxItems ?? 20);
}

/**
 * Extracts the top stress-related tags from stressful items.
 * Used by the AI agent to select appropriate Bible verses.
 */
export function extractStressTags(stressfulItems: StressfulItem[]): string[] {
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
    .filter(([tag]) => !INTERNAL_ONLY_TAGS.has(tag))
    .sort((a, b) => b[1] - a[1])
    .slice(0, 6)
    .map(([tag]) => tag);

  return rankedTags;
}

function calendarEventToStressfulItem(
  item: CalendarEventItem,
  options: HeuristicOptions,
): StressfulItem | null {
  const title = (item.title ?? item.summary ?? '').trim();
  if (!title) {
    return null;
  }

  const dueIso = item.dueAt ?? item.startAt ?? item.endAt;
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

  for (const keyword of extractKeywords(item.title ?? item.summary ?? '')) {
    tags.add(keyword);
  }
  for (const keyword of extractKeywords(item.description ?? '')) {
    tags.add(keyword);
  }

  const maxTags = options.maxTags ?? 10;
  const stressTags = Array.from(tags).slice(0, maxTags);

  return {
    type: item.kind,
    title,
    course: item.course,
    dueAt: dueDate ? dueDate.toISOString() : undefined,
    stressTags,
    weight: undefined,
  };
}
