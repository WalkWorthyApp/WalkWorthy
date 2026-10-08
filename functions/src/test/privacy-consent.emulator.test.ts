import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { initializeApp, deleteApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import type { Response } from 'express';
import type { Request } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';
import firebase = require('../shared/firebase');
import auth = require('../shared/auth');
import consent = require('../shared/privacy-consent');
import { privacyConsent, PRIVACY_CONSENT_READ_LIMIT } from '../api/privacy-consent';
import { deletionRef, AccountDeletingError } from '../shared/account-lifecycle';
import { consentRef, NOTICE_VERSION, savePrivacyConsent, ConsentConflict, requireAiConsent, AiConsentRequiredError } from '../shared/privacy-consent';
import { STANDARD_USER_LIMIT } from '../shared/rate-limiter';

const hasEmulator = Boolean(process.env.FIRESTORE_EMULATOR_HOST);

test('unexpected withdrawal failures log only safe diagnostics and return unavailable', async t => {
  t.mock.method(firebase, 'getDb', () => ({}));
  t.mock.method(auth, 'verifyAppCheck', async () => true);
  t.mock.method(auth, 'requireAuth', async (req: Request) => Object.assign(req, {userId: 'synthetic'}));
  t.mock.method(consent, 'consentRef', () => ({}));
  t.mock.method(consent, 'savePrivacyConsent', async () => {
    throw new TypeError('PRIVATE_SENTINEL: synthetic user data');
  });
  const errorLog = t.mock.method(logger, 'error', () => {});
  let status = 200;
  let payload: unknown;
  const response = {
    setHeader: () => response,
    status: (value: number) => {status = value; return response;},
    json: (value: unknown) => {payload = value; return response;},
  };
  await privacyConsent({method: 'PUT', body: {aiSharing: false}} as Request, response as unknown as Response);
  assert.equal(status, 503);
  assert.deepEqual(errorLog.mock.calls.map(call => call.arguments), [
    ['Privacy consent operation failed', {errorKind: 'TypeError'}],
  ]);
  assert.doesNotMatch(JSON.stringify(payload), /PRIVATE_SENTINEL/);
});

test('new withdrawals invalidate in-flight grants even when sharing is already off', {skip: !hasEmulator}, async () => {
  const app = initializeApp({projectId: 'demo-walkworthy-compliance'}, randomUUID());
  const db = getFirestore(app);
  const uid = `consent-order-${randomUUID()}`;
  try {
    const first = await savePrivacyConsent(db, uid, {aiSharing: false, withdrawalId: randomUUID()});
    const pendingGrant = {aiSharing: true, noticeVersion: NOTICE_VERSION, ageGroup: '18+', expectedRevision: first.revision} as const;
    const withdrawal = {aiSharing: false, withdrawalId: randomUUID()} as const;
    const second = await savePrivacyConsent(db, uid, withdrawal);
    assert.equal(second.revision, first.revision + 1);
    await assert.rejects(savePrivacyConsent(db, uid, pendingGrant), ConsentConflict);
    const beforeRetry = await consentRef(db, uid).get();
    assert.deepEqual(await savePrivacyConsent(db, uid, withdrawal), second);
    assert.ok((await consentRef(db, uid).get()).updateTime?.isEqual(beforeRetry.updateTime!));
    // An older client cannot identify retries, so each call invalidates old grants.
    const legacy = await savePrivacyConsent(db, uid, {aiSharing: false});
    assert.equal(legacy.revision, second.revision + 1);
    await assert.rejects(savePrivacyConsent(db, uid, {...pendingGrant, expectedRevision: second.revision}), ConsentConflict);
    await savePrivacyConsent(db, uid, {...pendingGrant, expectedRevision: legacy.revision});
    // A delayed retry must also revoke a grant made after the original withdrawal.
    const delayed = await savePrivacyConsent(db, uid, withdrawal);
    assert.equal(delayed.aiSharing, false);
    assert.equal(delayed.revision, legacy.revision + 2);
  } finally {
    await db.recursiveDelete(db.doc(`users/${uid}`));
    await deleteApp(app);
  }
});

test('withdrawal is durable, idempotent and invalidates stale grants and AI writes', {skip: !hasEmulator}, async () => {
  const app = initializeApp({projectId: 'demo-walkworthy-compliance'}, randomUUID());
  const db = getFirestore(app);
  const uid = `consent-${randomUUID()}`;
  const ref = consentRef(db, uid);
  const withdrawal = {aiSharing: false, withdrawalId: randomUUID()} as const;
  try {
    // Missing consent still needs a tombstone: an in-flight grant read revision 0.
    const withdrawn = await savePrivacyConsent(db, uid, withdrawal);
    assert.equal(withdrawn.aiSharing, false);
    assert.equal(withdrawn.revision, 1);
    await assert.rejects(savePrivacyConsent(db, uid, {
      aiSharing: true, noticeVersion: NOTICE_VERSION, ageGroup: '18+', expectedRevision: 0,
    }), ConsentConflict);
    const before = await ref.get();
    assert.deepEqual(await savePrivacyConsent(db, uid, withdrawal), withdrawn);
    assert.ok((await ref.get()).updateTime?.isEqual(before.updateTime!));

    const granted = await savePrivacyConsent(db, uid, {
      aiSharing: true, noticeVersion: NOTICE_VERSION, ageGroup: '18+', expectedRevision: withdrawn.revision,
    });
    const receipt = await requireAiConsent(db, uid);
    assert.equal(receipt.aiSharing, true);
    const revoked = await savePrivacyConsent(db, uid, {aiSharing: false});
    assert.equal(revoked.ageGroup, '18+'); // Keep the adult analytics unlock.
    assert.equal(revoked.revision, granted.revision + 1);
    const resultRef = db.doc(`users/${uid}/dailyReflections/late-result`);
    await assert.rejects(db.runTransaction(async tx => {
      await requireAiConsent(db, uid, tx, receipt.revision);
      tx.set(resultRef, {reflection: 'Must not persist'});
    }), AiConsentRequiredError);
    assert.equal((await resultRef.get()).exists, false);

    // A legacy grant parses as false but must still be explicitly withdrawn.
    await ref.set({...granted, noticeVersion: 'old'});
    assert.equal((await savePrivacyConsent(db, uid, {aiSharing: false})).aiSharing, false);
    assert.equal((await ref.get()).get('aiSharing'), false);

    await deletionRef(db, uid).set({status: 'deleting'});
    await assert.rejects(savePrivacyConsent(db, uid, {aiSharing: false}), AccountDeletingError);
  } finally {
    await db.recursiveDelete(db.doc(`users/${uid}`));
    await deletionRef(db, uid).delete();
    await deleteApp(app);
  }
});

test('foreground consent reads do not starve grants, and withdrawal bypasses both exhausted quotas', {skip: !hasEmulator}, async t => {
  const app = initializeApp({projectId: 'demo-walkworthy-compliance'}, randomUUID());
  const db = getFirestore(app);
  const uid = `consent-http-${randomUUID()}`;
  const readRef = db.collection('_rateLimits').doc(`user:${uid}:privacyConsent:read`);
  const grantRef = db.collection('_rateLimits').doc(`user:${uid}:privacyConsent:grant`);
  t.mock.method(firebase, 'getDb', () => db);
  // The real endpoint, validation, quota code and transactions run below.
  // Authentication is isolated from Firestore behavior; no live Auth/App Check.
  t.mock.method(auth, 'verifyAppCheck', async () => true);
  t.mock.method(auth, 'requireAuth', async (req: Request) => Object.assign(req, {userId: uid}));
  async function request(method: string, body?: unknown) {
    let status = 200;
    let payload: unknown;
    const response = {
      setHeader: () => response,
      set: () => response,
      status: (value: number) => {status = value; return response;},
      json: (value: unknown) => {payload = value; return response;},
    };
    await privacyConsent({method, body} as Request, response as unknown as Response);
    return {status, payload};
  }
  try {
    const grant = {aiSharing: true, noticeVersion: NOTICE_VERSION, ageGroup: '18+', expectedRevision: 0};
    for (let i = 0; i < 29; i++) {
      assert.equal((await request('GET')).status, 200);
    }
    // Both 29 and 30 earlier foreground refreshes must leave room for the
    // client's preflight GET followed by its separate consent grant.
    assert.equal((await request('GET')).status, 200);
    assert.equal((await request('PUT', grant)).status, 200);
    assert.equal((await request('GET')).status, 200);
    assert.equal((await request('PUT', {...grant, expectedRevision: 1})).status, 200);
    assert.equal((await request('PUT', grant)).status, 409);
    assert.equal((await readRef.get()).get('timestamps').length, 31);
    assert.equal((await grantRef.get()).get('timestamps').length, 3);

    // Seed the rest of each real sliding window to exercise its HTTP denial
    // without hundreds of redundant emulator round trips.
    const now = new Date().toISOString();
    await readRef.set({timestamps: Array(PRIVACY_CONSENT_READ_LIMIT.maxRequests).fill(now), updatedAt: now});
    await grantRef.set({timestamps: Array(STANDARD_USER_LIMIT.maxRequests).fill(now), updatedAt: now});
    const readQuotaBefore = await readRef.get();
    const grantQuotaBefore = await grantRef.get();
    assert.equal((await request('GET')).status, 429);
    assert.equal((await request('PUT', {...grant, expectedRevision: 2})).status, 429);
    const withdrawalId = randomUUID();
    assert.equal((await request('PUT', {aiSharing: false, withdrawalId})).status, 200);
    const receiptBeforeRetry = await consentRef(db, uid).get();
    assert.equal(receiptBeforeRetry.get('aiSharing'), false);
    assert.equal((await request('PUT', {aiSharing: false, withdrawalId, noticeVersion: 'old', expectedRevision: 0})).status, 200);
    assert.ok((await consentRef(db, uid).get()).updateTime?.isEqual(receiptBeforeRetry.updateTime!));
    assert.ok((await readRef.get()).updateTime?.isEqual(readQuotaBefore.updateTime!));
    assert.ok((await grantRef.get()).updateTime?.isEqual(grantQuotaBefore.updateTime!));
    assert.equal((await request('PUT', {aiSharing: false, unexpected: 'reject'})).status, 400);
  } finally {
    t.mock.restoreAll();
    await db.recursiveDelete(db.doc(`users/${uid}`));
    await readRef.delete();
    await grantRef.delete();
    await deleteApp(app);
  }
});
