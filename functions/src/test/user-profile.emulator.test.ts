import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test, { type TestContext } from 'node:test';
import { deleteApp, initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import type { Request } from 'firebase-functions/v2/https';
import type { Response } from 'express';
import firebase = require('../shared/firebase');
import auth = require('../shared/auth');
import { userProfile } from '../api/user-profile';
import { deleteAllUserFirestoreData } from '../shared/account-deletion';

const emulator = { skip: !process.env.FIRESTORE_EMULATOR_HOST };
// Fields earlier builds stored that the app no longer collects.
const retired = {
  gender: 'female', translationPreference: 'NIV', optInTailored: true,
  major: 'SYNTHETIC_MAJOR', occupation: 'SYNTHETIC_OCCUPATION', hobbies: ['SYNTHETIC_HOBBY'],
};

function fixture(t: TestContext) {
  const app = initializeApp({ projectId: 'demo-walkworthy-compliance' }, randomUUID());
  const db = getFirestore(app);
  const uid = `user-profile-${randomUUID()}`;
  const profile = db.doc(`users/${uid}/profile/data`);
  t.mock.method(firebase, 'getDb', () => db);
  t.mock.method(auth, 'verifyAppCheck', async () => true);
  t.mock.method(auth, 'requireAuth', async (req: Request) => Object.assign(req, { userId: uid }));
  t.after(async () => {
    t.mock.restoreAll();
    await deleteAllUserFirestoreData(db, uid);
    await deleteApp(app);
  });
  return { profile };
}

async function patch(body: Record<string, unknown>) {
  let status = 200;
  const response = {
    setHeader: () => response, set: () => response,
    status: (value: number) => { status = value; return response; },
    json: () => response,
  };
  await userProfile({ method: 'PATCH', body, query: {} } as unknown as Request, response as unknown as Response);
  return status;
}

test('profile save purges every retired field', emulator, async t => {
  const { profile } = fixture(t);
  await profile.set({ ageRange: '18-24', firstName: 'Sam', timezone: 'UTC', ...retired });
  assert.equal(await patch({ ageRange: '25-34', firstName: 'Sam', timezone: 'UTC' }), 200);
  const saved = (await profile.get()).data() ?? {};
  assert.deepEqual(Object.keys(saved).sort(), ['ageRange', 'firstName', 'timezone', 'updatedAt']);
  assert.equal(saved.ageRange, '25-34');
});

test('retired fields sent by a client are never stored', emulator, async t => {
  const { profile } = fixture(t);
  assert.equal(await patch(retired), 400, 'a request with only retired fields updates nothing');
  assert.equal((await profile.get()).exists, false);
  assert.equal(await patch({ firstName: 'Sam', ...retired }), 200);
  assert.deepEqual(Object.keys((await profile.get()).data() ?? {}).sort(), ['firstName', 'updatedAt']);
});

test('saving a birth date stores it and deletes the legacy age range', emulator, async t => {
  const { profile } = fixture(t);
  await profile.set({ ageRange: '18-24', firstName: 'Sam', timezone: 'UTC' });
  assert.equal(await patch({ birthDate: '1999-06-15', firstName: 'Sam', timezone: 'UTC' }), 200);
  const saved = (await profile.get()).data() ?? {};
  assert.deepEqual(Object.keys(saved).sort(), ['birthDate', 'firstName', 'timezone', 'updatedAt']);
  assert.equal(saved.birthDate, '1999-06-15');
});

test('an invalid or under-18 birth date is refused without writing anything', emulator, async t => {
  const { profile } = fixture(t);
  await profile.set({ ageRange: '18-24', firstName: 'Sam', timezone: 'UTC' });
  const nextYear = new Date().getUTCFullYear() + 1;
  for (const birthDate of [`${nextYear - 17}-01-01`, '1999-02-30', '06/15/1999']) {
    assert.equal(await patch({ birthDate, firstName: 'Changed' }), 400, birthDate);
  }
  assert.deepEqual((await profile.get()).data(), { ageRange: '18-24', firstName: 'Sam', timezone: 'UTC' });
});
