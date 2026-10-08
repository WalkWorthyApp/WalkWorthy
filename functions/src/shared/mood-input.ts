import type { MoodSpectrumData } from './types';

/** A retry is identical only when all submitted context is unchanged. */
export function sameMoodInput(stored: Partial<MoodSpectrumData> | null | undefined, input: MoodSpectrumData): boolean {
  const sameSelections = (left: unknown, right: readonly string[]): boolean =>
    Array.isArray(left) && left.length === right.length &&
    JSON.stringify([...left].sort()) === JSON.stringify([...right].sort());
  return stored != null && stored.moodScore === input.moodScore &&
    stored.followUpScore === input.followUpScore &&
    (stored.note ?? null) === input.note &&
    sameSelections(stored.emotionTags, input.emotionTags) &&
    sameSelections(stored.impactCategories, input.impactCategories);
}
