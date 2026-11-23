import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test, { type TestContext } from 'node:test';
import { deleteApp, initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { deleteAllUserFirestoreData } from '../shared/account-deletion';
import { deletionRef, AccountDeletingError } from '../shared/account-lifecycle';
import { storeCode, checkCode, verificationCodeRef, CODE_TTL_MS, MAX_CODE_ATTEMPTS } from '../shared/email-verification';

const emulator = { skip: !process.env.FIRESTORE_EMULATOR_HOST };

function fixture(t: TestContext) {
  const app = initializeApp({ projectId: 'demo-walkworthy-compliance' }, randomUUID());
  const db = getFirestore(app);
  const uid = `email-code-${randomUUID()}`;
  t.after(async () => {
    await deletionRef(db, uid).delete();
    await deleteAllUserFirestoreData(db, uid);
    await deleteApp(app);
  });
  return { db, uid };
}

test('only a hash is stored and a correct code works exactly once', emulator, async t => {
  const { db, uid } = fixture(t);
  await storeCode(db, uid, 'User@Example.com', '135790');
  const stored = (await verificationCodeRef(db, uid).get()).data();
  assert.ok(stored);
  assert.doesNotMatch(JSON.stringify(stored), /135790/);
  assert.equal(await checkCode(db, uid, 'user@example.com', '135790'), 'verified');
  assert.equal(await checkCode(db, uid, 'user@example.com', '135790'), 'expired');
});

test('a resend replaces the earlier code', emulator, async t => {
  const { db, uid } = fixture(t);
  await storeCode(db, uid, 'a@example.com', '111111');
  await storeCode(db, uid, 'a@example.com', '222222');
  assert.equal(await checkCode(db, uid, 'a@example.com', '111111'), 'invalid');
  assert.equal(await checkCode(db, uid, 'a@example.com', '222222'), 'verified');
});

test('wrong guesses are capped and then the code is discarded', emulator, async t => {
  const { db, uid } = fixture(t);
  await storeCode(db, uid, 'a@example.com', '424242');
  for (let i = 1; i < MAX_CODE_ATTEMPTS; i++) assert.equal(await checkCode(db, uid, 'a@example.com', '000000'), 'invalid');
  assert.equal(await checkCode(db, uid, 'a@example.com', '000000'), 'tooManyAttempts');
  assert.equal(await checkCode(db, uid, 'a@example.com', '424242'), 'expired');
});

test('a code expires and is bound to the address it was sent to', emulator, async t => {
  const { db, uid } = fixture(t);
  const now = Date.now();
  await storeCode(db, uid, 'a@example.com', '555555', now);
  assert.equal(await checkCode(db, uid, 'a@example.com', '555555', now + CODE_TTL_MS + 1), 'expired');
  await storeCode(db, uid, 'a@example.com', '555555');
  assert.equal(await checkCode(db, uid, 'b@example.com', '555555'), 'expired');
});

test('account deletion blocks codes and erases them', emulator, async t => {
  const { db, uid } = fixture(t);
  await storeCode(db, uid, 'a@example.com', '999999');
  await deleteAllUserFirestoreData(db, uid);
  assert.equal((await verificationCodeRef(db, uid).get()).exists, false);
  await deletionRef(db, uid).set({ requestedAt: new Date() });
  await assert.rejects(storeCode(db, uid, 'a@example.com', '999999'), AccountDeletingError);
});
