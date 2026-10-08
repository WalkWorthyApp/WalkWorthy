import type { Firestore, Transaction } from 'firebase-admin/firestore';

/** Outside the user subtree so recursive deletion cannot remove the write barrier. */
export const deletionRef = (db: Firestore, uid: string) => db.collection('_accountDeletions').doc(uid);
export class AccountDeletingError extends Error {
  constructor() { super('Account deletion is in progress'); }
}
export async function assertAccountActive(db: Firestore, uid: string, tx?: Transaction): Promise<void> {
  const ref = deletionRef(db, uid);
  const snap = tx ? await tx.get(ref) : await ref.get();
  if (snap.exists) throw new AccountDeletingError();
}
