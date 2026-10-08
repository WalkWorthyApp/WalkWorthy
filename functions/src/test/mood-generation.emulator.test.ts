import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test, { type TestContext } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { deleteApp, initializeApp } from 'firebase-admin/app';
import { getFirestore, Timestamp } from 'firebase-admin/firestore';
import type { Request } from 'firebase-functions/v2/https';
import type { Response } from 'express';
import firebase = require('../shared/firebase');
import auth = require('../shared/auth');
import profile = require('../shared/profile');
import agent = require('../lib/mood-agent');
import generation = require('../shared/mood-generation');
import { moodCheckIn } from '../api/mood-checkin';
import { deleteAllUserFirestoreData } from '../shared/account-deletion';
import { NOTICE_VERSION, savePrivacyConsent } from '../shared/privacy-consent';
import { getTodayUtcDateString } from '../shared/rate-limiter';
import { AccountDeletingError, deletionRef } from '../shared/account-lifecycle';
import { getLogicalDateString } from '../shared/time';

const emulator = { skip: !process.env.FIRESTORE_EMULATOR_HOST };
const base = { moodScore: 5, followUpScore: 2, emotionTags: ['Calm', 'Hopeful'],
  impactCategories: ['Work', 'Family'], note: 'Synthetic context' };

async function fixture(t: TestContext) {
  const app = initializeApp({ projectId: 'demo-walkworthy-compliance' }, randomUUID());
  const db = getFirestore(app);
  const uid = `mood-claim-${randomUUID()}`;
  t.mock.method(firebase, 'getDb', () => db);
  t.mock.method(auth, 'verifyAppCheck', async () => true);
  t.mock.method(auth, 'requireAuth', async (req: Request) => Object.assign(req, { userId: uid }));
  t.mock.method(profile, 'getUserProfileOnce', async () => ({ timezone: 'UTC', optInTailored: false }));
  await savePrivacyConsent(db, uid, { aiSharing: true, noticeVersion: NOTICE_VERSION, ageGroup: '18+', expectedRevision: 0 });
  t.after(async () => {
    t.mock.restoreAll();
    await deleteAllUserFirestoreData(db, uid);
    await deleteApp(app);
  });
  return {
    db, uid,
    budget: () => db.doc(`_dailyBudgets/${uid}_${getTodayUtcDateString()}`).get(),
    async post(data = base, options: Record<string, unknown> = {}) {
      let status = 200;
      let body: Record<string, unknown> = {};
      const headers: Record<string, string> = {};
      const response = {
        setHeader: (name: string, value: string) => { headers[name] = value; return response; },
        set: (name: string, value: string) => { headers[name] = value; return response; },
        status: (value: number) => { status = value; return response; },
        json: (value: Record<string, unknown>) => { body = value; return response; },
      };
      await moodCheckIn({ method: 'POST', body: { checkInType: 'morning', moodSpectrumData: data, ...options } } as Request,
        response as unknown as Response);
      return { status, body, headers };
    },
  };
}

function gate() {
  let release = () => {};
  const promise = new Promise<void>(resolve => { release = resolve; });
  return { promise, release };
}

function identity(note = base.note): generation.MoodGenerationIdentity {
  return { checkInDocId: '2026-10-08_morning', input: { ...base, note, moodLevel: 'neutral' },
    regenerate: false, baseVersion: 'absent', profileContext: null };
}

async function owner(f: Awaited<ReturnType<typeof fixture>>, input = identity()) {
  const result = await generation.claimMoodGeneration(f.db, f.uid, input);
  assert.equal(result.type, 'owner');
  if (result.type !== 'owner') throw new Error('Expected ownership');
  return result.claim;
}

function paidStub(t: TestContext) {
  return t.mock.method(agent, 'runMoodAgent', async (_input: agent.MoodAgentInput, _key: string,
    _check: unknown, _model: unknown, _generate: unknown, beforeGeneration?: () => Promise<void>) => {
    await beforeGeneration?.();
    return agent.CRISIS_RESPONSE;
  });
}

test('overlapping identical mood requests generate once and keep the hourly admissions', emulator, async t => {
  const f = await fixture(t);
  const started = gate();
  const finish = gate();
  let generations = 0;
  t.mock.method(agent, 'runMoodAgent', async (_input: agent.MoodAgentInput, _key: string, _check: unknown, _model: unknown, _generate: unknown, beforeGeneration?: () => Promise<void>) => {
    await beforeGeneration?.();
    generations++;
    started.release();
    await finish.promise;
    return agent.CRISIS_RESPONSE;
  });
  const first = f.post();
  await started.promise;
  const second = f.post({ ...base, emotionTags: [...base.emotionTags].reverse(),
    impactCategories: [...base.impactCategories].reverse() });
  await delay(300);
  finish.release();
  const responses = await Promise.all([first, second]);
  assert.deepEqual(responses.map(r => r.status), [201, 201]);
  assert.deepEqual(responses[0].body, responses[1].body);
  assert.equal(generations, 1);
  assert.equal((await f.budget()).get('callCount'), 1);
  assert.equal((await f.db.doc(`_rateLimits/user:${f.uid}:moodCheckIn:write`).get()).get('timestamps').length, 2);
});

test('failed generation retains the reservation once provider work has started', emulator, async t => {
  const f = await fixture(t);
  t.mock.method(agent, 'runMoodAgent', async (_input: agent.MoodAgentInput, _key: string, _check: unknown, _model: unknown, _generate: unknown, beforeGeneration?: () => Promise<void>) => {
    await beforeGeneration?.();
    throw new Error('Synthetic provider error after dispatch');
  });
  assert.equal((await f.post()).status, 500);
  assert.equal((await f.budget()).get('callCount'), 1);
});

for (const regenerate of [false, true]) {
  test(`overlapping ${regenerate ? 'regeneration' : 'updates'} coalesce; later explicit regeneration remains eligible`, emulator, async t => {
    const f = await fixture(t);
    const originalAgent = paidStub(t);
    const saved = await f.post();
    originalAgent.mock.restore();
    const started = gate();
    const finish = gate();
    const joined = gate();
    const originalWait = generation.waitForMoodGeneration;
    t.mock.method(generation, 'waitForMoodGeneration', async (claim: generation.MoodGenerationClaim) => {
      joined.release();
      return originalWait(claim);
    });
    let generations = 0;
    t.mock.method(agent, 'runMoodAgent', async (_input: agent.MoodAgentInput, _key: string,
      _check: unknown, _model: unknown, _generate: unknown, beforeGeneration?: () => Promise<void>) => {
      await beforeGeneration?.();
      generations++;
      started.release();
      await finish.promise;
      return agent.CRISIS_RESPONSE;
    });
    const data = regenerate ? base : { ...base, note: 'Changed context' };
    const options = regenerate ? { regenerate: true, expectedCheckInId: saved.body.checkInId } : {};
    const first = f.post(data, options);
    await started.promise;
    const second = f.post(data, options);
    try {
      await Promise.race([joined.promise, delay(5000).then(() => { throw new Error('Follower did not join'); })]);
    } finally { finish.release(); }
    const [one, two] = await Promise.all([first, second]);
    assert.deepEqual(one, two);
    assert.equal(one.status, 201);
    assert.equal(generations, 1);
    assert.equal((await f.budget()).get('callCount'), 2);
    assert.equal((await f.post(data, { regenerate: true, expectedCheckInId: saved.body.checkInId })).status, 201);
    assert.equal(generations, 2);
    assert.equal((await f.budget()).get('callCount'), 3);
  });
}

test('fixed responses and pre-dispatch failures release reservations, while write failures retain consumed work', emulator, async t => {
  const f = await fixture(t);
  let mock = t.mock.method(agent, 'runMoodAgent', async () => { throw new Error('Failure before dispatch'); });
  assert.equal((await f.post()).status, 500);
  assert.equal((await f.budget()).get('callCount'), 0);
  mock.mock.restore();
  mock = t.mock.method(agent, 'runMoodAgent', async () => agent.CRISIS_RESPONSE);
  assert.equal((await f.post()).status, 201);
  assert.equal((await f.budget()).get('callCount'), 0);
  mock.mock.restore();
  paidStub(t);
  t.mock.method(generation, 'completeMoodGeneration', () => { throw new Error('Synthetic write failure'); });
  assert.equal((await f.post({ ...base, note: 'New paid context' })).status, 500);
  assert.equal((await f.budget()).get('callCount'), 1);
  const saved = await f.db.doc(`users/${f.uid}/moodCheckIns/${getLogicalDateString('UTC')}_morning`).get();
  assert.equal(saved.get('moodSpectrumData.note'), base.note);
});

test('consent errors keep their response and only refund before provider dispatch', emulator, async t => {
  const f = await fixture(t);
  await savePrivacyConsent(f.db, f.uid, { aiSharing: false });
  let response = await f.post();
  assert.equal(response.status, 403);
  assert.equal(response.body.code, 'AI_CONSENT_REQUIRED');
  assert.equal((await f.budget()).get('callCount'), 0);
  await savePrivacyConsent(f.db, f.uid, { aiSharing: true, noticeVersion: NOTICE_VERSION, ageGroup: '18+', expectedRevision: 2 });
  t.mock.method(agent, 'runMoodAgent', async (_input: agent.MoodAgentInput, _key: string,
    _check: unknown, _model: unknown, _generate: unknown, beforeGeneration?: () => Promise<void>) => {
    await beforeGeneration?.();
    await savePrivacyConsent(f.db, f.uid, { aiSharing: false });
    return agent.CRISIS_RESPONSE;
  });
  response = await f.post();
  assert.equal(response.status, 403);
  assert.equal(response.body.code, 'AI_CONSENT_REQUIRED');
  assert.equal((await f.budget()).get('callCount'), 1);
});

test('claim admission atomically shares one reservation and enforces the remaining daily quota', emulator, async t => {
  const f = await fixture(t);
  const claims = await Promise.all(Array.from({ length: 5 }, () => generation.claimMoodGeneration(f.db, f.uid, identity())));
  assert.equal(claims.filter(c => c.type === 'owner').length, 1);
  assert.equal(claims.filter(c => c.type === 'follower').length, 4);
  assert.equal((await f.budget()).get('callCount'), 1);
  await (await f.budget()).ref.update({ callCount: 14 });
  const lastSlots = await Promise.all(['Different A', 'Different B'].map(note =>
    generation.claimMoodGeneration(f.db, f.uid, identity(note))));
  assert.equal(lastSlots.filter(c => c.type === 'owner').length, 1);
  assert.equal(lastSlots.filter(c => c.type === 'denied').length, 1);
  assert.equal((await f.budget()).get('callCount'), 15);
});

test('expired consumed claims retain charges and fence the former owner at every boundary', emulator, async t => {
  const f = await fixture(t);
  const first = await owner(f);
  await generation.markMoodGenerationConsumed(first);
  await first.ref.update({ leaseUntil: Timestamp.fromMillis(0) });
  const replacement = await owner(f);
  assert.notEqual(replacement.owner, first.owner);
  assert.equal((await f.budget()).get('callCount'), 2);
  await assert.rejects(generation.markMoodGenerationConsumed(first), generation.MoodGenerationConflictError);
  await assert.rejects(f.db.runTransaction(tx => generation.readMoodGenerationSettlement(tx, first)), generation.MoodGenerationConflictError);
  await assert.rejects(generation.waitForMoodGeneration(first), generation.MoodGenerationConflictError);
  await generation.failMoodGeneration(first);
  assert.equal((await replacement.ref.get()).get('owner'), replacement.owner);
  assert.equal((await f.budget()).get('callCount'), 2);
  await generation.markMoodGenerationConsumed(replacement);
  const result = { checkInId: 'replacement', aiResponse: agent.CRISIS_RESPONSE, createdAt: 'now', expiresAt: 'later' };
  await f.db.runTransaction(async tx => {
    const settlement = await generation.readMoodGenerationSettlement(tx, replacement);
    generation.completeMoodGeneration(tx, replacement, settlement, result);
  });
  await generation.failMoodGeneration(replacement);
  assert.deepEqual(await generation.waitForMoodGeneration(replacement), result);
  assert.equal((await f.budget()).get('callCount'), 2);
});

test('UTC rollover refunds the captured day once and reclaims an unstarted expired reservation', emulator, async t => {
  const f = await fixture(t);
  let now = Date.parse('2026-10-08T23:59:59.000Z');
  t.mock.method(Date, 'now', () => now);
  const old = await owner(f);
  const expired = await owner(f, identity('Another context'));
  const oldBudget = f.db.doc(`_dailyBudgets/${f.uid}_2026-10-08`);
  const newBudget = f.db.doc(`_dailyBudgets/${f.uid}_2026-10-09`);
  assert.equal(old.budgetDate, '2026-10-08');
  now = Date.parse('2026-10-09T00:02:00.000Z');
  await newBudget.set({ date: '2026-10-09', callCount: 4 });
  await generation.failMoodGeneration(old);
  await generation.failMoodGeneration(old);
  assert.equal((await oldBudget.get()).get('callCount'), 1);
  assert.equal((await newBudget.get()).get('callCount'), 4);
  const reclaimed = await owner(f, identity('Another context'));
  assert.notEqual(reclaimed.owner, expired.owner);
  assert.equal(reclaimed.budgetDate, '2026-10-09');
  assert.equal((await oldBudget.get()).get('callCount'), 0);
  assert.equal((await newBudget.get()).get('callCount'), 5);
  await generation.failMoodGeneration(expired);
  assert.equal((await newBudget.get()).get('callCount'), 5);
});

test('deletion prevents claim dispatch, settlement, cleanup and resurrection', emulator, async t => {
  const f = await fixture(t);
  const claim = await owner(f);
  const marker = deletionRef(f.db, f.uid);
  try {
    await marker.set({ status: 'deleting' });
    await assert.rejects(generation.markMoodGenerationConsumed(claim), AccountDeletingError);
    await assert.rejects(generation.claimMoodGeneration(f.db, f.uid, identity('Other')), AccountDeletingError);
    await assert.rejects(f.db.runTransaction(tx => generation.readMoodGenerationSettlement(tx, claim)), AccountDeletingError);
    await deleteAllUserFirestoreData(f.db, f.uid);
    await assert.rejects(generation.failMoodGeneration(claim), AccountDeletingError);
    assert.equal((await claim.ref.get()).exists, false);
    assert.equal((await f.budget()).exists, false);
  } finally { await marker.delete(); }
});

test('a consumed loser across intervening input versions keeps its charge', emulator, async t => {
  const f = await fixture(t);
  const started = gate();
  const finish = gate();
  let calls = 0;
  t.mock.method(agent, 'runMoodAgent', async (_input: agent.MoodAgentInput, _key: string,
    _check: unknown, _model: unknown, _generate: unknown, beforeGeneration?: () => Promise<void>) => {
    await beforeGeneration?.();
    if (++calls === 1) { started.release(); await finish.promise; }
    return agent.CRISIS_RESPONSE;
  });
  const first = f.post();
  await started.promise;
  let latest: Awaited<ReturnType<typeof f.post>>;
  try {
    assert.equal((await f.post({ ...base, note: 'Intervening context' })).status, 201);
    latest = await f.post();
  } finally { finish.release(); }
  assert.deepEqual(await first, latest);
  assert.equal(calls, 3);
  assert.equal((await f.budget()).get('callCount'), 3);
});

test('coalesced failures preserve consent errors, while saved content remains readable after withdrawal', emulator, async t => {
  const f = await fixture(t);
  const started = gate();
  const finish = gate();
  const joined = gate();
  const originalWait = generation.waitForMoodGeneration;
  const waiting = t.mock.method(generation, 'waitForMoodGeneration', async (claim: generation.MoodGenerationClaim) => {
    joined.release();
    return originalWait(claim);
  });
  const mock = t.mock.method(agent, 'runMoodAgent', async (_input: agent.MoodAgentInput, _key: string,
    _check: unknown, _model: unknown, _generate: unknown, beforeGeneration?: () => Promise<void>) => {
    await beforeGeneration?.();
    started.release();
    await finish.promise;
    return agent.CRISIS_RESPONSE;
  });
  const first = f.post();
  await started.promise;
  const second = f.post();
  try {
    await Promise.race([joined.promise, delay(5000).then(() => { throw new Error('Follower did not join'); })]);
    await savePrivacyConsent(f.db, f.uid, { aiSharing: false });
  } finally { finish.release(); }
  const responses = await Promise.all([first, second]);
  assert.deepEqual(responses.map(r => [r.status, r.body.code]), [[403, 'AI_CONSENT_REQUIRED'], [403, 'AI_CONSENT_REQUIRED']]);
  assert.equal((await f.budget()).get('callCount'), 1);
  mock.mock.restore();
  waiting.mock.restore();
  await savePrivacyConsent(f.db, f.uid, { aiSharing: true, noticeVersion: NOTICE_VERSION, ageGroup: '18+', expectedRevision: 2 });
  paidStub(t);
  assert.equal((await f.post()).status, 201);
  await savePrivacyConsent(f.db, f.uid, { aiSharing: false });
  const cached = await f.post();
  assert.equal(cached.status, 200);
  assert.equal(cached.body.isExisting, true);
  assert.equal((await f.budget()).get('callCount'), 2);
});

test('followers receive the same reviewed fixed response even when a profile word appears in it', emulator, async t => {
  const f = await fixture(t);
  t.mock.method(profile, 'getUserProfileOnce', async () => ({ timezone: 'UTC', optInTailored: false, hobbies: ['words'] }));
  const started = gate();
  const finish = gate();
  const joined = gate();
  const originalWait = generation.waitForMoodGeneration;
  t.mock.method(generation, 'waitForMoodGeneration', async (claim: generation.MoodGenerationClaim) => {
    joined.release();
    return originalWait(claim);
  });
  t.mock.method(agent, 'runMoodAgent', async () => {
    started.release();
    await finish.promise;
    return agent.CRISIS_RESPONSE;
  });
  const first = f.post();
  await started.promise;
  const second = f.post();
  try {
    await Promise.race([joined.promise, delay(5000).then(() => { throw new Error('Follower did not join'); })]);
  } finally { finish.release(); }
  const results = await Promise.all([first, second]);
  assert.deepEqual(results.map(r => r.status), [201, 201]);
  assert.deepEqual(results[0].body, results[1].body);
  assert.equal((await f.budget()).get('callCount'), 0);
});
