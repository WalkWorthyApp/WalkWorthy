import assert from 'node:assert/strict';
import test from 'node:test';
import { deleteApp, getApps, initializeApp } from 'firebase-admin/app';
import { FieldPath, Timestamp, getFirestore } from 'firebase-admin/firestore';
import type { Firestore } from 'firebase-admin/firestore';
import { randomUUID } from 'node:crypto';
import { requestAccountDeletion, resumeAccountDeletion, retryPendingAccountDeletions } from '../shared/account-deletion';
import { deleteAllUserFirestoreData } from '../api/delete-account';
import { AccountDeletingError, deletionRef } from '../shared/account-lifecycle';
import { consentRef, NOTICE_VERSION, requireAiConsent } from '../shared/privacy-consent';

const hasEmulator = typeof process.env.FIRESTORE_EMULATOR_HOST === 'string';

async function withDeletionFixture(run: (db: Firestore, uid: string) => Promise<void>) {
  const app = initializeApp({projectId: 'demo-walkworthy-compliance'}, randomUUID());
  const db = getFirestore(app);
  const uid = `deletion-${randomUUID()}`;
  try { await run(db, uid); }
  finally {
    await deleteAllUserFirestoreData(db, uid);
    await deletionRef(db, uid).delete();
    await deleteApp(app);
  }
}

test('new jobs require recent authentication before any durable deletion side effects', {skip: !hasEmulator}, async () => {
  await withDeletionFixture(async (db, uid) => {
    const profile = db.doc(`users/${uid}/profile/data`);
    const quota = db.doc(`_rateLimits/user:${uid}:fixture`);
    await profile.set({firstName: 'Synthetic'});
    await quota.set({count: 1});
    let authTime: unknown;
    let deleteCalls = 0;
    const checks: boolean[] = [];
    const auth = {
      verifyIdToken: async (_token: string, checkRevoked = false) => {
        checks.push(checkRevoked);
        return {uid, auth_time: authTime};
      },
      deleteUser: async () => {deleteCalls++;},
    };
    const now = Math.floor(Date.now() / 1000);
    for (authTime of [undefined, null, String(now), NaN, Infinity, now - 0.5, 0, -1, now + 60, now - 301]) {
      await assert.rejects(requestAccountDeletion(db, auth, 'synthetic'), {code: 'auth/requires-recent-login'});
      assert.equal((await deletionRef(db, uid).get()).exists, false);
      assert.deepEqual((await profile.get()).data(), {firstName: 'Synthetic'});
      assert.deepEqual((await quota.get()).data(), {count: 1});
      assert.equal(deleteCalls, 0);
      assert.deepEqual(checks.splice(0), [false, true]);
    }
    authTime = Math.floor(Date.now() / 1000);
    assert.deepEqual(await requestAccountDeletion(db, auth, 'synthetic'), {status: 'completed'});
    assert.equal((await profile.get()).exists, false);
    assert.equal((await quota.get()).exists, false);
    assert.equal(deleteCalls, 1);
  });
});

test('accepted client and worker retries finish after freshness and the Auth user are gone', {skip: !hasEmulator}, async () => {
  for (const source of ['client', 'worker'] as const) {
    await withDeletionFixture(async (db, uid) => {
      const profile = db.doc(`users/${uid}/profile/data`);
      await profile.set({firstName: 'Synthetic'});
      await deletionRef(db, uid).set({status: 'deleting', nextAttemptAt: Timestamp.fromMillis(0)});
      const checks: boolean[] = [];
      const auth = {
        verifyIdToken: async (_token: string, checkRevoked = false) => {
          checks.push(checkRevoked);
          if (checkRevoked) throw Object.assign(new Error('Gone'), {code: 'auth/user-not-found'});
          return {uid, auth_time: Math.floor(Date.now() / 1000) - 3600};
        },
        deleteUser: async () => {throw Object.assign(new Error('Gone'), {code: 'auth/user-not-found'});},
      };
      if (source === 'client') {
        assert.deepEqual(await requestAccountDeletion(db, auth, 'synthetic'), {status: 'completed'});
        assert.deepEqual(checks, [false]);
      } else {
        assert.ok((await retryPendingAccountDeletions(db, auth)).completed >= 1);
        assert.deepEqual(checks, []);
      }
      assert.equal((await profile.get()).exists, false);
      assert.equal((await deletionRef(db, uid).get()).get('status'), 'completed');
    });
  }
});

test('deletion rejects revoked tokens before writes and completed retries stay read-only', {skip: !hasEmulator}, async () => {
  await withDeletionFixture(async (db, uid) => {
    let revoked = true;
    let deleted = false;
    let revocationChecks = 0;
    const auth = {
      verifyIdToken: async (_token: string, checkRevoked?: boolean) => {
        if (checkRevoked) {
          revocationChecks++;
          if (revoked) throw Object.assign(new Error('Revoked'), {code: 'auth/id-token-revoked'});
          if (deleted) throw Object.assign(new Error('Gone'), {code: 'auth/user-not-found'});
        }
        return {uid, auth_time: Math.floor(Date.now() / 1000)};
      },
      deleteUser: async () => {deleted = true;},
    };
    const marker = deletionRef(db, uid);
    for (let i = 0; i < 4; i++) await assert.rejects(requestAccountDeletion(db, auth, 'synthetic'), {code: 'auth/id-token-revoked'});
    assert.equal((await marker.get()).exists, false);
    const rateRef = db.doc(`_rateLimits/user:${uid}:deleteAccount`);
    assert.equal((await rateRef.get()).exists, false);

    revoked = false;
    await db.doc(`users/${uid}/profile/data`).set({firstName: 'Synthetic'});
    assert.equal((await requestAccountDeletion(db, auth, 'synthetic')).status, 'completed');
    const before = await marker.get();
    assert.equal(revocationChecks, 5);
    for (let i = 0; i < 4; i++) assert.equal((await requestAccountDeletion(db, auth, 'synthetic')).status, 'completed');
    assert.equal(revocationChecks, 5);
    assert.ok((await marker.get()).updateTime?.isEqual(before.updateTime!));
    assert.equal((await rateRef.get()).exists, false);
    assert.equal((await db.doc(`users/${uid}`).listCollections()).length, 0);
  });
});

test('failed deletion keeps a durable barrier and hourly quota; worker recovers without a user retry', {skip: !hasEmulator}, async () => {
  await withDeletionFixture(async (db, uid) => {
    let failAuthDeletion = true;
    let authDeleted = false;
    let authTime: number | undefined = Math.floor(Date.now() / 1000);
    const auth = {
      verifyIdToken: async () => ({uid, auth_time: authTime}),
      deleteUser: async () => {
        if (failAuthDeletion) throw new Error('Synthetic transient auth failure');
        authDeleted = true;
      },
    };
    const marker = deletionRef(db, uid);
    for (let i = 0; i < 3; i++) {
      await assert.rejects(requestAccountDeletion(db, auth, 'synthetic'));
      const pending = await marker.get();
      assert.equal(pending.get('status'), 'deleting');
      assert.equal(pending.get('expiresAt'), undefined);
      assert.equal(pending.get('clientAttempts').length, i + 1);
      // Freshness authorizes only initial acceptance, not subsequent recovery.
      authTime = undefined;
    }
    const limited = await requestAccountDeletion(db, auth, 'synthetic');
    assert.equal(limited.status, 'rate-limited');
    if (limited.status === 'rate-limited') assert.ok(limited.retryAfterSeconds > 0);
    await assert.rejects(requireAiConsent(db, uid), AccountDeletingError);

    // The scheduler finds this due job even after the client stops retrying.
    await marker.update({nextAttemptAt: Timestamp.fromMillis(Date.now() - 1000)});
    failAuthDeletion = false;
    const recovered = await retryPendingAccountDeletions(db, auth);
    assert.ok(recovered.completed >= 1);
    assert.equal(authDeleted, true);
    const completed = await marker.get();
    assert.equal(completed.get('status'), 'completed');
    assert.ok(completed.get('expiresAt') instanceof Timestamp);
    assert.equal(completed.get('clientAttempts'), undefined);
    assert.equal(completed.get('nextAttemptAt'), undefined);
  });
});

test('worker removes remaining data after partial cleanup and reclaims an expired lease', {skip: !hasEmulator}, async () => {
  await withDeletionFixture(async (db, uid) => {
    const removed = db.doc(`users/${uid}/profile/data`);
    const remaining = db.doc(`users/${uid}/moodCheckIns/remaining`);
    await removed.set({firstName: 'Synthetic'});
    await remaining.set({note: 'Synthetic test fixture'});
    let deletedAuth = false;
    const auth = {deleteUser: async () => {deletedAuth = true;}};
    await deletionRef(db, uid).set({status: 'deleting'});
    await assert.rejects(resumeAccountDeletion(db, auth, uid, 'client', async () => {
      await removed.delete();
      throw new Error('Synthetic interrupted cleanup');
    }));
    assert.equal((await remaining.get()).exists, true);
    assert.equal(deletedAuth, false);
    const marker = deletionRef(db, uid);
    assert.equal((await marker.get()).get('expiresAt'), undefined);
    // Also models a process killed before it could release its lease.
    const expired = Timestamp.fromMillis(Date.now() - 1000);
    await marker.update({leaseId: 'crashed-worker', leaseUntil: expired, nextAttemptAt: expired});
    await retryPendingAccountDeletions(db, auth);
    assert.equal((await remaining.get()).exists, false);
    assert.equal(deletedAuth, true);
    assert.equal((await marker.get()).get('status'), 'completed');
  });
});

test('concurrent deletion attempts share a lease and cannot recreate quota records', {skip: !hasEmulator}, async () => {
  await withDeletionFixture(async (db, uid) => {
    let release: () => void = () => {};
    let started: () => void = () => {};
    const gate = new Promise<void>(resolve => {release = resolve;});
    const ready = new Promise<void>(resolve => {started = resolve;});
    const auth = {deleteUser: async () => {}};
    await deletionRef(db, uid).set({status: 'deleting'});
    const first = resumeAccountDeletion(db, auth, uid, 'client', async () => {
      started();
      await gate;
      await deleteAllUserFirestoreData(db, uid);
    });
    await ready;
    try {
      assert.equal((await resumeAccountDeletion(db, auth, uid, 'client')).status, 'busy');
      assert.equal((await resumeAccountDeletion(db, auth, uid, 'worker')).status, 'busy');
      assert.equal((await deletionRef(db, uid).get()).get('clientAttempts').length, 1);
    } finally { release(); }
    assert.equal((await first).status, 'completed');
    assert.equal((await db.doc(`_rateLimits/user:${uid}:deleteAccount`).get()).exists, false);
  });
});

test('account deletion recursively removes user data and paginates operational records', {
  skip: hasEmulator ? false : 'requires the Firestore emulator',
}, async () => {
  const projectId = process.env.GCLOUD_PROJECT ?? 'demo-walkworthy-compliance';
  const appName = `account-deletion-${Date.now()}`;
  const app = initializeApp({ projectId }, appName);
  const db = getFirestore(app);
  const uid = `delete-fixture-${Date.now()}`;
  const legacyIpId = `ip:203.0.113.10:moodCheckIn`;

  try {
    await db.doc(`users/${uid}/profile/data`).set({ firstName: 'Synthetic' });
    await db.doc(`users/${uid}/moodCheckIns/day/nested/value`).set({ value: true });

    for (let offset = 0; offset < 405; offset += 400) {
      const batch = db.batch();
      for (let index = offset; index < Math.min(offset + 400, 405); index += 1) {
        batch.set(db.collection('_rateLimits').doc(`user:${uid}:fixture:${String(index).padStart(3, '0')}`), { count: 1 });
        batch.set(db.collection('_dailyBudgets').doc(`${uid}_${String(index).padStart(3, '0')}`), { callCount: 1 });
      }
      await batch.commit();
    }
    await db.collection('_rateLimits').doc(legacyIpId).set({ count: 1 });

    await deleteAllUserFirestoreData(db, uid);

    const userCollections = await db.collection('users').doc(uid).listCollections();
    assert.equal(userCollections.length, 0);

    const ratePrefix = `user:${uid}:`;
    const remainingRates = await db.collection('_rateLimits')
      .where(FieldPath.documentId(), '>=', ratePrefix)
      .where(FieldPath.documentId(), '<', `${ratePrefix}\uf8ff`)
      .get();
    assert.equal(remainingRates.size, 0);

    const budgetPrefix = `${uid}_`;
    const remainingBudgets = await db.collection('_dailyBudgets')
      .where(FieldPath.documentId(), '>=', budgetPrefix)
      .where(FieldPath.documentId(), '<', `${budgetPrefix}\uf8ff`)
      .get();
    assert.equal(remainingBudgets.size, 0);
    assert.equal((await db.collection('_rateLimits').doc(legacyIpId).get()).exists, true);
  } finally {
    await db.recursiveDelete(db.collection('users').doc(uid));
    await db.collection('_rateLimits').doc(legacyIpId).delete();
    await deleteApp(app);
    for (const existing of getApps()) {
      if (existing.name === appName) await deleteApp(existing);
    }
  }
});

test('deletion barrier and recursive cleanup leave no data after a paused AI transaction', {
  skip: hasEmulator ? false : 'requires the Firestore emulator',
}, async () => {
  const projectId = process.env.GCLOUD_PROJECT ?? 'demo-walkworthy-compliance';
  const appName = `deletion-race-${Date.now()}`;
  const app = initializeApp({ projectId }, appName);
  const db = getFirestore(app);
  const uid = `race-fixture-${Date.now()}`;
  const resultRef = db.doc(`users/${uid}/dailyReflections/result`);
  let releaseFirstAttempt: (() => void) | undefined;
  let signalFirstRead: (() => void) | undefined;
  const firstRead = new Promise<void>((resolve) => { signalFirstRead = resolve; });
  const continueTransaction = new Promise<void>((resolve) => { releaseFirstAttempt = resolve; });
  let attempts = 0;

  try {
    await consentRef(db, uid).set({
      aiSharing: true,
      noticeVersion: NOTICE_VERSION,
      ageGroup: '18+',
      revision: 1,
      updatedAt: new Date().toISOString(),
    });

    const pendingWrite = db.runTransaction(async (tx) => {
      attempts += 1;
      await requireAiConsent(db, uid, tx, 1);
      if (attempts === 1) {
        signalFirstRead?.();
        await continueTransaction;
      }
      tx.set(resultRef, { shouldNotExist: true });
    });

    await firstRead;
    const pendingBarrier = deletionRef(db, uid).set({ status: 'deleting' });
    releaseFirstAttempt?.();

    const [writeResult, barrierResult] = await Promise.allSettled([pendingWrite, pendingBarrier]);
    assert.equal(barrierResult.status, 'fulfilled');
    if (writeResult.status === 'rejected') {
      assert.ok(writeResult.reason instanceof AccountDeletingError);
    }
    await deleteAllUserFirestoreData(db, uid);
    assert.equal((await resultRef.get()).exists, false);
    assert.equal((await consentRef(db, uid).get()).exists, false);
  } finally {
    await db.recursiveDelete(db.collection('users').doc(uid));
    await deletionRef(db, uid).delete();
    await deleteApp(app);
  }
});
