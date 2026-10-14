import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test, { type TestContext } from 'node:test';
import { deleteApp, initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import type { Request } from 'firebase-functions/v2/https';
import type { Response } from 'express';
import firebase = require('../shared/firebase');
import auth = require('../shared/auth');
import { suggestion, SUGGESTION_USER_LIMIT } from '../api/suggestion';
import { deleteAllUserFirestoreData } from '../shared/account-deletion';
import { deletionRef } from '../shared/account-lifecycle';
import { suggestionRef } from '../shared/suggestion';

const emulator = { skip: !process.env.FIRESTORE_EMULATOR_HOST };

function fixture(t: TestContext) {
  const app = initializeApp({ projectId: 'demo-walkworthy-compliance' }, randomUUID());
  const db = getFirestore(app);
  const uid = `suggestion-${randomUUID()}`;
  t.mock.method(firebase, 'getDb', () => db);
  t.mock.method(auth, 'verifyAppCheck', async () => true);
  t.mock.method(auth, 'requireAuth', async (req: Request) => Object.assign(req, { userId: uid }));
  t.after(async () => {
    t.mock.restoreAll();
    await deletionRef(db, uid).delete();
    await deleteAllUserFirestoreData(db, uid);
    await deleteApp(app);
  });
  return { db, uid };
}

async function post(body: Record<string, unknown>) {
  let status = 200;
  let payload: unknown;
  const response = {
    setHeader: () => response, set: () => response,
    status: (value: number) => { status = value; return response; },
    json: (value: unknown) => { payload = value; return response; },
  };
  await suggestion({ method: 'POST', body } as unknown as Request, response as unknown as Response);
  return { status, payload };
}

const body = () => ({ id: randomUUID(), category: 'confusing', text: '  The mood slider is hard to read  ', appVersion: 'v1.0 (1)' });

test('a suggestion is stored once under the user, even when resent', emulator, async t => {
  const { db, uid } = fixture(t);
  const request = body();
  assert.deepEqual(await post(request), { status: 201, payload: { id: request.id } });
  assert.deepEqual(await post(request), { status: 200, payload: { id: request.id } });
  const saved = await db.collection(`users/${uid}/suggestions`).get();
  assert.equal(saved.size, 1);
  const data = saved.docs[0].data();
  assert.deepEqual(Object.keys(data).sort(), ['appVersion', 'category', 'createdAt', 'text']);
  assert.equal(data.text, 'The mood slider is hard to read');
  assert.equal(data.category, 'confusing');
});

test('the daily limit stops further suggestions', emulator, async t => {
  fixture(t);
  for (let i = 0; i < SUGGESTION_USER_LIMIT.maxRequests; i += 1) {
    assert.equal((await post(body())).status, 201);
  }
  assert.equal((await post(body())).status, 429);
});

test('no suggestion is written once account deletion has started', emulator, async t => {
  const { db, uid } = fixture(t);
  await deletionRef(db, uid).set({ state: 'pending' });
  const request = body();
  assert.equal((await post(request)).status, 403);
  assert.equal((await suggestionRef(db, uid, request.id).get()).exists, false);
});

test('account deletion erases suggestions', emulator, async t => {
  const { db, uid } = fixture(t);
  const request = body();
  assert.equal((await post(request)).status, 201);
  await deleteAllUserFirestoreData(db, uid);
  assert.equal((await suggestionRef(db, uid, request.id).get()).exists, false);
});
