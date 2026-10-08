import type { Firestore, Transaction } from 'firebase-admin/firestore';
import { sanitizeProfile, type UserProfilePayload } from '../lib/profile-sanitize';

/** A single generation attempt, including the exact profile it may disclose. */
export interface PersonalizationAttempt {
  readonly profile: UserProfilePayload | null;
  /** Also usable by a request-scoped provider gate before sending this attempt. */
  isCurrent(transaction?: Transaction): Promise<boolean>;
}

export const NO_PERSONALIZATION: PersonalizationAttempt = Object.freeze({
  profile: null,
  isCurrent: async () => true,
});

/** Request-local state: never share between requests or cache on an agent. */
export interface AiPersonalization {
  /** Recheck after moderation/backoff and rebuild the prompt from this attempt. */
  forGeneration(): Promise<PersonalizationAttempt>;
  /** Validate the last attempt when committing its generated result. */
  isResultCurrent(transaction: Transaction): Promise<boolean>;
}

/**
 * Bind an immutable, sanitized profile to Firestore's server-owned revision.
 * PUT/PATCH/DELETE (including opt-out/regrant) invalidate it without a schema
 * migration. Even unrelated profile edits conservatively disable this snapshot.
 * Read failures propagate; they never authorize sharing. A successful check
 * cannot make a later provider request atomic with a concurrent profile write.
 */
export async function createAiPersonalization(
  db: Firestore,
  uid: string,
  checkConsent: (transaction: Transaction) => Promise<void>,
): Promise<AiPersonalization> {
  const ref = db.collection('users').doc(uid).collection('profile').doc('data');
  const snapshot = await ref.get();
  const revision = snapshot.updateTime;
  let permitted = NO_PERSONALIZATION;
  if (snapshot.exists && revision && snapshot.get('optInTailored') === true) {
    const profile = sanitizeProfile(snapshot.data() as UserProfilePayload)!;
    if (profile.hobbies) Object.freeze(profile.hobbies);
    Object.freeze(profile);
    permitted = Object.freeze({
      profile,
      async isCurrent(transaction?: Transaction): Promise<boolean> {
        const validate = async (tx: Transaction) => {
          await checkConsent(tx);
          const current = await tx.get(ref);
          return current.exists && current.get('optInTailored') === true &&
            current.updateTime !== undefined && revision.isEqual(current.updateTime);
        };
        // A new profile read must not outlive a stale base-consent observation.
        // Default read/write transactions hold both records through commit;
        // never use a readOnly snapshot or perform provider I/O inside this tx.
        return transaction ? validate(transaction) : db.runTransaction(validate);
      },
    });
  }

  let lastAttempt = NO_PERSONALIZATION;
  return {
    async forGeneration() {
      lastAttempt = await permitted.isCurrent() ? permitted : NO_PERSONALIZATION;
      return lastAttempt;
    },
    isResultCurrent: transaction => lastAttempt.isCurrent(transaction),
  };
}
