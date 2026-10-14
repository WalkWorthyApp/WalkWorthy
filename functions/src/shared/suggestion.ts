import type { Firestore } from 'firebase-admin/firestore';
import { FieldValue } from 'firebase-admin/firestore';
import { assertAccountActive } from './account-lifecycle';

export const SUGGESTION_CATEGORIES = ['idea', 'confusing', 'other'] as const;
export type SuggestionCategory = typeof SUGGESTION_CATEGORIES[number];
/** Counted in Unicode code points, matching the app's `unicodeScalars.count`. */
export const SUGGESTION_MAX_LENGTH = 1000;

export interface SuggestionInput {
  id: string;
  category: SuggestionCategory;
  text: string;
  appVersion?: string;
}

/** Under the user's document so account deletion's recursive delete erases it. */
export const suggestionRef = (db: Firestore, uid: string, id: string) =>
  db.collection('users').doc(uid).collection('suggestions').doc(id);

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const APP_VERSION_RE = /^[0-9A-Za-z.() -]{1,32}$/;

export function validateSuggestionInput(body: unknown): SuggestionInput | null {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return null;
  const b = body as Record<string, unknown>;
  if (Object.keys(b).some(k => !['id', 'category', 'text', 'appVersion'].includes(k))) return null;
  if (typeof b.id !== 'string' || !UUID_RE.test(b.id)) return null;
  if (typeof b.category !== 'string' || !(SUGGESTION_CATEGORIES as readonly string[]).includes(b.category)) return null;
  if (typeof b.text !== 'string') return null;
  const text = b.text.trim();
  if (text.length === 0 || [...text].length > SUGGESTION_MAX_LENGTH) return null;
  if (b.appVersion !== undefined && (typeof b.appVersion !== 'string' || !APP_VERSION_RE.test(b.appVersion))) return null;
  return {
    // The client reuses one ID across resends; normalize so a retry matches.
    id: b.id.toLowerCase(),
    category: b.category as SuggestionCategory,
    text,
    ...(b.appVersion !== undefined ? { appVersion: b.appVersion as string } : {}),
  };
}

/**
 * Stores a suggestion once. Resending the same ID (a retry after a dropped
 * response) is a no-op that reports `created: false`. The deletion barrier is
 * read in the same transaction so a write cannot land after account deletion.
 */
export async function saveSuggestion(db: Firestore, uid: string, input: SuggestionInput): Promise<{ created: boolean }> {
  return db.runTransaction(async tx => {
    await assertAccountActive(db, uid, tx);
    const ref = suggestionRef(db, uid, input.id);
    if ((await tx.get(ref)).exists) return { created: false };
    tx.create(ref, {
      category: input.category,
      text: input.text,
      ...(input.appVersion !== undefined ? { appVersion: input.appVersion } : {}),
      createdAt: FieldValue.serverTimestamp(),
    });
    return { created: true };
  });
}
