import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { deleteApp, initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import type { Request } from 'firebase-functions/v2/https';
import type { Response } from 'express';
import firebase = require('../shared/firebase');
import auth = require('../shared/auth');
import profile = require('../shared/profile');
import agent = require('../lib/mood-agent');
import { moodCheckIn } from '../api/mood-checkin';
import { deleteAllUserFirestoreData } from '../shared/account-deletion';
import { NOTICE_VERSION, savePrivacyConsent } from '../shared/privacy-consent';
import { getLogicalDateString } from '../shared/time';

test('mood retries reuse identical content but persist changed context, including concurrent requests', {
  skip: !process.env.FIRESTORE_EMULATOR_HOST,
}, async t => {
  const app = initializeApp({ projectId: 'demo-walkworthy-compliance' }, randomUUID());
  const db = getFirestore(app);
  const uid = `mood-retry-${randomUUID()}`;
  t.mock.method(firebase, 'getDb', () => db);
  t.mock.method(auth, 'verifyAppCheck', async () => true);
  t.mock.method(auth, 'requireAuth', async (req: Request) => Object.assign(req, { userId: uid }));
  t.mock.method(profile, 'getUserProfileOnce', async () => ({ timezone: 'UTC', optInTailored: false }));
  let generations = 0;
  let release: () => void = () => {};
  let started: () => void = () => {};
  const gate = new Promise<void>(resolve => { release = resolve; });
  const ready = new Promise<void>(resolve => { started = resolve; });
  t.mock.method(agent, 'runMoodAgent', async (input: agent.MoodAgentInput) => {
    generations++;
    if (input.moodSpectrumData.note === 'Waiting context') {
      started();
      await gate;
    }
    return agent.CRISIS_RESPONSE;
  });
  const base = { moodScore: 5, followUpScore: 2, emotionTags: ['Calm'], impactCategories: ['Work'], note: 'Original context' };
  async function post(data: typeof base, checkInType = 'morning') {
    let status = 200;
    let payload: unknown;
    const response = {
      setHeader: () => response,
      set: () => response,
      status: (value: number) => { status = value; return response; },
      json: (value: unknown) => { payload = value; return response; },
    };
    await moodCheckIn({ method: 'POST', body: { checkInType, moodSpectrumData: data } } as Request, response as unknown as Response);
    assert.ok(status === 200 || status === 201, JSON.stringify({ status, payload }));
    return payload;
  }
  try {
    await savePrivacyConsent(db, uid, { aiSharing: true, noticeVersion: NOTICE_VERSION, ageGroup: '18+', expectedRevision: 0 });
    const today = getLogicalDateString('UTC');
    const saved = db.doc(`users/${uid}/moodCheckIns/${today}_morning`);
    await post(base);
    await post(base); // A saved response lost in transit must be safe to retry.
    assert.equal(generations, 1);
    assert.deepEqual((await saved.get()).get('aiResponse'), agent.CRISIS_RESPONSE);

    const changedNote = { ...base, note: 'Revised context after retry' };
    await post(changedNote);
    assert.equal(generations, 2);
    assert.equal((await saved.get()).get('moodSpectrumData.note'), changedNote.note);

    const changedTags = { ...changedNote, emotionTags: ['Anxious'], impactCategories: ['Family'] };
    await post(changedTags);
    assert.equal(generations, 3);
    assert.deepEqual((await saved.get()).get('moodSpectrumData.emotionTags'), ['Anxious']);
    assert.deepEqual((await saved.get()).get('moodSpectrumData.impactCategories'), ['Family']);
    await post(changedTags);
    assert.equal(generations, 3);

    // Both requests see an empty slot before generating. The slower request
    // must not mistake the other's different note for its own saved result.
    const waiting = post({ ...base, note: 'Waiting context' }, 'midday');
    await ready;
    try { await post({ ...base, note: 'Concurrent context' }, 'midday'); }
    finally { release(); }
    await waiting;
    assert.equal((await db.doc(`users/${uid}/moodCheckIns/${today}_midday`).get()).get('moodSpectrumData.note'), 'Waiting context');

  } finally {
    release();
    t.mock.restoreAll();
    await deleteAllUserFirestoreData(db, uid);
    await deleteApp(app);
  }
});

test('regeneration targets the displayed check-in and cannot create or replace another day', {
  skip: !process.env.FIRESTORE_EMULATOR_HOST,
}, async t => {
  const app = initializeApp({ projectId: 'demo-walkworthy-compliance' }, randomUUID());
  const db = getFirestore(app);
  const uid = `mood-regenerate-${randomUUID()}`;
  t.mock.method(firebase, 'getDb', () => db);
  t.mock.method(auth, 'verifyAppCheck', async () => true);
  t.mock.method(auth, 'requireAuth', async (req: Request) => Object.assign(req, { userId: uid }));
  t.mock.method(profile, 'getUserProfileOnce', async () => ({ timezone: 'UTC', optInTailored: false }));
  let generations = 0;
  t.mock.method(agent, 'runMoodAgent', async () => {
    generations++;
    return agent.CRISIS_RESPONSE;
  });
  const data = { moodScore: 5, followUpScore: 2, emotionTags: ['Calm'], impactCategories: ['Work'] };
  async function post(options: { regenerate?: boolean; expectedCheckInId?: string } = {}) {
    let status = 200;
    let payload: unknown;
    const response = {
      setHeader: () => response,
      set: () => response,
      status: (value: number) => { status = value; return response; },
      json: (value: unknown) => { payload = value; return response; },
    };
    await moodCheckIn({ method: 'POST', body: { checkInType: 'morning', moodSpectrumData: data, ...options } } as Request,
      response as unknown as Response);
    return { status, payload };
  }
  try {
    await savePrivacyConsent(db, uid, { aiSharing: true, noticeVersion: NOTICE_VERSION, ageGroup: '18+', expectedRevision: 0 });
    const today = getLogicalDateString('UTC');
    const saved = db.doc(`users/${uid}/moodCheckIns/${today}_morning`);
    const summary = db.doc(`users/${uid}/moodSummaries/${today}`);
    // An old response's ID cannot create a new day's empty slot.
    assert.equal((await post({ regenerate: true, expectedCheckInId: 'previous-day-id' })).status, 409);
    assert.equal((await saved.get()).exists, false);
    assert.equal((await summary.get()).exists, false);
    assert.equal(generations, 0);

    assert.equal((await post()).status, 201);
    const original = await saved.get();
    const checkInId = original.get('id') as string;
    // Nor can it replace a newer check-in saved on this or another device.
    assert.equal((await post({ regenerate: true, expectedCheckInId: 'previous-day-id' })).status, 409);
    assert.equal((await post({ regenerate: true })).status, 409);
    assert.ok((await saved.get()).updateTime?.isEqual(original.updateTime!));
    assert.equal(generations, 1);

    assert.equal((await post({ regenerate: true, expectedCheckInId: checkInId })).status, 201);
    assert.equal(generations, 2);
    assert.equal((await saved.get()).get('id'), checkInId);

    // Recheck identity at the write boundary, after generation yields.
    t.mock.method(agent, 'runMoodAgent', async () => {
      await saved.update({ id: 'replacement-id' });
      return agent.CRISIS_RESPONSE;
    });
    assert.equal((await post({ regenerate: true, expectedCheckInId: checkInId })).status, 409);
    assert.equal((await saved.get()).get('id'), 'replacement-id');
    const budget = await db.collection('_dailyBudgets').get();
    const ownBudgets = budget.docs.filter(doc => doc.id.startsWith(`${uid}_`));
    assert.equal(ownBudgets.reduce((sum, doc) => sum + Number(doc.get('callCount')), 0), 2);
  } finally {
    t.mock.restoreAll();
    await deleteAllUserFirestoreData(db, uid);
    await deleteApp(app);
  }
});
