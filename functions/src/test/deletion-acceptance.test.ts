import assert from 'node:assert/strict';
import test from 'node:test';
import type { Firestore } from 'firebase-admin/firestore';
import type { Request } from 'firebase-functions/v2/https';
import type { Response } from 'express';
import firebase = require('../shared/firebase');
import authMiddleware = require('../shared/auth');
import { deleteAccount } from '../api/delete-account';
import { PendingDeletionError, requestAccountDeletion, resumeAccountDeletion } from '../shared/account-deletion';

test('deletion acceptance failures do not promise a retry without a confirmed job', async t => {
  t.mock.method(authMiddleware, 'verifyAppCheck', async () => true);
  t.mock.method(firebase, 'getAuthInstance', () => ({verifyIdToken: async () => ({uid: 'synthetic'})}));
  for (const failAt of ['read', 'claim'] as const) {
    const db = {
      collection: () => ({doc: () => ({get: async () => {
        if (failAt === 'read') throw new Error('Synthetic read failure');
        return {data: () => undefined};
      }})}),
      runTransaction: async () => {throw new Error('Synthetic claim failure');},
    };
    t.mock.method(firebase, 'getDb', () => db);
    let status = 0;
    let payload: {message: string} | undefined;
    const response = {
      setHeader: () => response,
      status: (value: number) => {status = value; return response;},
      json: (value: {message: string}) => {payload = value; return response;},
    };
    await deleteAccount({method: 'POST', headers: {authorization: 'Bearer synthetic'}} as Request, response as unknown as Response);
    assert.equal(status, 503);
    assert.match(payload!.message, /could not confirm/);
    assert.match(payload!.message, /retry/);
    assert.doesNotMatch(payload!.message, /automatically/);
  }
});

test('accepted cleanup retains its pending classification even when lease release fails', async () => {
  const cleanupFailure = new Error('Synthetic cleanup failure');
  const releaseFailure = new Error('Synthetic release failure');
  let transactions = 0;
  const db = {
    collection: () => ({doc: () => ({})}),
    runTransaction: async (run: (tx: unknown) => Promise<unknown>) => {
      if (++transactions > 1) throw releaseFailure;
      return run({get: async () => ({data: () => undefined}), set: () => {}});
    },
  } as unknown as Firestore;
  await assert.rejects(resumeAccountDeletion(db, {deleteUser: async () => {}}, 'synthetic', 'client', async () => {
    throw cleanupFailure;
  }), error => error instanceof PendingDeletionError && error.cause === cleanupFailure && error.releaseError === releaseFailure);
});

test('a previously accepted job remains pending when a subsequent claim fails', async () => {
  const db = {
    collection: () => ({doc: () => ({get: async () => ({data: () => ({status: 'deleting'})})})}),
    runTransaction: async () => {throw new Error('Synthetic claim failure');},
  } as unknown as Firestore;
  await assert.rejects(requestAccountDeletion(db, {
    verifyIdToken: async () => ({uid: 'synthetic'}), deleteUser: async () => {},
  }, 'synthetic'), PendingDeletionError);
});

test('HTTP accepted failures promise recovery while revoked requests remain unauthorized', async t => {
  const db = {
    collection: () => ({doc: () => ({get: async () => ({data: () => ({status: 'deleting'})})})}),
    runTransaction: async () => {throw new Error('Synthetic claim failure');},
  };
  t.mock.method(firebase, 'getDb', () => db);
  t.mock.method(authMiddleware, 'verifyAppCheck', async () => true);
  for (const revoked of [false, true]) {
    t.mock.method(firebase, 'getAuthInstance', () => ({verifyIdToken: async () => {
      if (revoked) throw Object.assign(new Error('Revoked'), {code: 'auth/id-token-revoked'});
      return {uid: 'synthetic'};
    }}));
    let status = 0;
    let payload: {message: string} | undefined;
    const response = {
      setHeader: () => response,
      status: (value: number) => {status = value; return response;},
      json: (value: {message: string}) => {payload = value; return response;},
    };
    await deleteAccount({method: 'POST', headers: {authorization: 'Bearer synthetic'}} as Request, response as unknown as Response);
    assert.equal(status, revoked ? 401 : 503);
    if (!revoked) assert.match(payload!.message, /automatically/);
  }
});
