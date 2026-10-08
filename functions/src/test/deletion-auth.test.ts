import assert from 'node:assert/strict';
import test from 'node:test';
import type { Firestore } from 'firebase-admin/firestore';
import type { Request } from 'firebase-functions/v2/https';
import type { Response } from 'express';
import firebase = require('../shared/firebase');
import authMiddleware = require('../shared/auth');
import { deleteAccount } from '../api/delete-account';
import { requestAccountDeletion, resumeAccountDeletion } from '../shared/account-deletion';

const NOW = 1_790_000_000_000;
const UID = 'synthetic-recent-deletion';
const RECENT_AUTH_ERROR = {code: 'auth/requires-recent-login'};
type Marker = Record<string, unknown> | undefined;
type Transaction = {
  get: () => Promise<{data: () => Marker}>;
  set: (ref: unknown, value: Record<string, unknown>) => void;
};

/** Buffer transaction writes until commit, including discarded retry attempts. */
function fixture(authTime: unknown, initialMarker?: Marker) {
  const state = {
    marker: initialMarker,
    checkedAuthTime: authTime,
    verificationError: undefined as string | undefined,
    revocationError: undefined as string | undefined,
    beforeClaim: undefined as (() => void) | undefined,
    retryClaim: undefined as (() => void) | undefined,
    verificationCalls: [] as boolean[],
    writes: 0,
    cleanupCalls: 0,
    deleteCalls: 0,
  };
  const snapshot = () => {
    const value = state.marker;
    return {data: () => value};
  };
  const ref = {get: async () => snapshot()};
  const query = {where: () => query, limit: () => query, get: async () => ({empty: true})};
  const db = {
    collection: () => ({doc: () => ref, where: () => query}),
    recursiveDelete: async () => {state.cleanupCalls++;},
    runTransaction: async (run: (tx: Transaction) => Promise<unknown>) => {
      state.beforeClaim?.();
      state.beforeClaim = undefined;
      let pending = state.marker;
      let writes = 0;
      const tx = {
        get: async () => snapshot(),
        set: (_ref: unknown, value: Record<string, unknown>) => {pending = value; writes++;},
      };
      let result = await run(tx);
      if (state.retryClaim) {
        state.retryClaim();
        state.retryClaim = undefined;
        pending = state.marker;
        writes = 0;
        result = await run(tx);
      }
      state.marker = pending;
      state.writes += writes;
      return result;
    },
  } as unknown as Firestore;
  const auth = {
    verifyIdToken: async (_token: string, checkRevoked = false) => {
      state.verificationCalls.push(checkRevoked);
      const code = state.verificationError ?? (checkRevoked ? state.revocationError : undefined);
      if (code) throw Object.assign(new Error('Synthetic authentication rejection'), {code});
      return {uid: UID, auth_time: checkRevoked ? state.checkedAuthTime : authTime, iat: NOW / 1000};
    },
    deleteUser: async () => {state.deleteCalls++;},
  };
  return {state, db, auth};
}

function assertNoDeletion(state: ReturnType<typeof fixture>['state']) {
  assert.equal(state.writes, 0);
  assert.equal(state.cleanupCalls, 0);
  assert.equal(state.deleteCalls, 0);
}

test('new deletion rejects missing, invalid, future and stale authentication before writes', async t => {
  t.mock.method(Date, 'now', () => NOW);
  const invalid = [undefined, null, true, String(NOW / 1000), NaN, Infinity, -Infinity,
    NOW / 1000 - 0.5, 0, -1, NOW, NOW / 1000 + 1, NOW / 1000 - 301];
  for (const authTime of invalid) {
    const {state, db, auth} = fixture(authTime);
    await assert.rejects(requestAccountDeletion(db, auth, 'synthetic'), RECENT_AUTH_ERROR);
    assertNoDeletion(state);
    assert.equal(state.marker, undefined);
    assert.deepEqual(state.verificationCalls, [false, true]);
  }
});

test('new deletion accepts recent authentication and the inclusive five-minute boundary', async t => {
  t.mock.method(Date, 'now', () => NOW);
  for (const ageSeconds of [0, 60, 300]) {
    const {state, db, auth} = fixture(NOW / 1000 - ageSeconds);
    assert.deepEqual(await requestAccountDeletion(db, auth, 'synthetic'), {status: 'completed'});
    assert.deepEqual(state.verificationCalls, [false, true]);
    assert.equal(state.cleanupCalls, 1);
    assert.equal(state.deleteCalls, 1);
    assert.equal(state.marker?.status, 'completed');
  }
});

test('creation uses revocation-checked claims and keeps revocation denials ahead of writes', async t => {
  t.mock.method(Date, 'now', () => NOW);
  const checkedClaims = fixture(NOW / 1000);
  checkedClaims.state.checkedAuthTime = NOW / 1000 - 301;
  await assert.rejects(requestAccountDeletion(checkedClaims.db, checkedClaims.auth, 'synthetic'), RECENT_AUTH_ERROR);
  assertNoDeletion(checkedClaims.state);
  for (const code of ['auth/id-token-revoked', 'auth/user-disabled', 'auth/user-not-found']) {
    const {state, db, auth} = fixture(NOW / 1000);
    state.revocationError = code;
    await assert.rejects(requestAccountDeletion(db, auth, 'synthetic'), {code});
    assertNoDeletion(state);
  }
});

test('new authorization must remain recent when the claim runs or its transaction retries', async t => {
  let now = NOW;
  t.mock.method(Date, 'now', () => now);
  for (const delay of ['beforeClaim', 'retryClaim'] as const) {
    now = NOW;
    const {state, db, auth} = fixture(NOW / 1000 - 300);
    state[delay] = () => {now += 1;};
    await assert.rejects(requestAccountDeletion(db, auth, 'synthetic'), RECENT_AUTH_ERROR);
    assertNoDeletion(state);
    assert.equal(state.marker, undefined);
  }
});

test('accepted requests can resume without recent authentication or a surviving Auth user', async t => {
  t.mock.method(Date, 'now', () => NOW);
  for (const authTime of [undefined, NOW / 1000 - 3600]) {
    const {state, db, auth} = fixture(authTime, {status: 'deleting'});
    state.revocationError = 'auth/user-not-found';
    assert.deepEqual(await requestAccountDeletion(db, auth, 'synthetic'), {status: 'completed'});
    assert.deepEqual(state.verificationCalls, [false]);
    assert.equal(state.cleanupCalls, 1);
    assert.equal(state.deleteCalls, 1);
  }
  const {state, db, auth} = fixture(undefined, {status: 'completed'});
  assert.deepEqual(await requestAccountDeletion(db, auth, 'synthetic'), {status: 'completed'});
  assertNoDeletion(state);
  assert.deepEqual(state.verificationCalls, [false]);
});

test('accepted and completed requests still require valid unexpired signed tokens', async () => {
  for (const status of ['deleting', 'completed']) {
    for (const code of ['auth/id-token-expired', 'auth/invalid-id-token']) {
      const {state, db, auth} = fixture(undefined, {status});
      state.verificationError = code;
      await assert.rejects(requestAccountDeletion(db, auth, 'synthetic'), {code});
      assertNoDeletion(state);
    }
  }
});

test('a pending pre-read cannot authorize creation if the transaction sees no accepted job', async t => {
  t.mock.method(Date, 'now', () => NOW);
  for (const replacement of [undefined, {status: 'unknown'}]) {
    const {state, db, auth} = fixture(NOW / 1000, {status: 'deleting'});
    state.beforeClaim = () => {state.marker = replacement;};
    await assert.rejects(requestAccountDeletion(db, auth, 'synthetic'), RECENT_AUTH_ERROR);
    assertNoDeletion(state);
    assert.deepEqual(state.verificationCalls, [false]);
  }
});

test('ordinary client resumes and workers cannot create missing or unknown-status jobs', async () => {
  for (const initial of [undefined, {status: 'unknown'}]) {
    for (const source of ['client', 'worker'] as const) {
      const {state, db, auth} = fixture(undefined, initial);
      const result = resumeAccountDeletion(db, auth, UID, source);
      if (source === 'worker') assert.deepEqual(await result, {status: 'busy'});
      else await assert.rejects(result, RECENT_AUTH_ERROR);
      assertNoDeletion(state);
    }
  }
});

test('HTTP new authorization failures return sign-in 401 without promising accepted recovery', async t => {
  t.mock.method(Date, 'now', () => NOW);
  t.mock.method(authMiddleware, 'verifyAppCheck', async () => true);
  for (const race of [false, true]) {
    const {state, db, auth} = fixture(NOW / 1000 - 301, race ? {status: 'deleting'} : undefined);
    if (race) state.beforeClaim = () => {state.marker = undefined;};
    t.mock.method(firebase, 'getDb', () => db);
    t.mock.method(firebase, 'getAuthInstance', () => auth);
    let status = 0;
    let payload: unknown;
    const headers: Record<string, string> = {};
    const response = {
      setHeader: (name: string, value: string) => {headers[name] = value; return response;},
      status: (value: number) => {status = value; return response;},
      json: (value: unknown) => {payload = value; return response;},
    };
    await deleteAccount({method: 'POST', headers: {authorization: 'Bearer synthetic'}} as Request,
      response as unknown as Response);
    assert.equal(status, 401);
    assert.deepEqual(payload, {error: 'Unauthorized', message: 'Sign in again to delete your account'});
    assert.equal(headers['Cache-Control'], 'private, no-store');
    assertNoDeletion(state);
  }
});
