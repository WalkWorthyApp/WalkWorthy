import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test, { type TestContext } from 'node:test';
import { deleteApp, initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import type { Request } from 'firebase-functions/v2/https';
import type { Response } from 'express';
import firebase = require('../shared/firebase');
import auth = require('../shared/auth');
import profiles = require('../shared/profile');
import personalization = require('../shared/ai-personalization');
import moodAgent = require('../lib/mood-agent');
import reflectionAgent = require('../lib/reflection-agent');
import modelConfig = require('../lib/model-config');
import { moodCheckIn } from '../api/mood-checkin';
import { dailyReflection } from '../api/daily-reflection';
import { userProfile } from '../api/user-profile';
import { NOTICE_VERSION, savePrivacyConsent } from '../shared/privacy-consent';
import { deleteAllUserFirestoreData } from '../shared/account-deletion';
import { getLogicalDateString } from '../shared/time';
import type { UserProfilePayload } from '../lib/profile-sanitize';

const hasEmulator = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
const profileData = {
  timezone: 'UTC', optInTailored: true, ageRange: '18-24',
  major: '<b>SYNTHETIC_PROFILE_MAJOR</b>', hobbies: ['SYNTHETIC_HOBBY'],
  occupation: 'SYNTHETIC_OCCUPATION', firstName: 'SYNTHETIC_PRIVATE_NAME',
  checkInTimes: { morning: '08:00', midday: '12:00', evening: '20:00' },
};
const sanitizedProfile = {
  optInTailored: true, ageRange: '18-24',
  major: 'SYNTHETIC_PROFILE_MAJOR', hobbies: ['SYNTHETIC_HOBBY'], occupation: 'SYNTHETIC_OCCUPATION',
};
const note = 'A synthetic check-in note';
const generatedText = 'Take a quiet moment today.';

function deferred() {
  let resolve: () => void = () => {};
  const promise = new Promise<void>(done => { resolve = done; });
  return { promise, resolve };
}

type Endpoint = (req: Request, res: Response) => void | Promise<void>;
async function invoke(handler: Endpoint, method: string, body?: Record<string, unknown>) {
  let status = 200;
  let payload: unknown;
  const response = {
    setHeader: () => response, set: () => response,
    status: (value: number) => { status = value; return response; },
    json: (value: unknown) => { payload = value; return response; },
  };
  await handler({ method, body, query: {} } as Request, response as unknown as Response);
  return { status, payload };
}

function fixture(t: TestContext) {
  const app = initializeApp({ projectId: 'demo-walkworthy-compliance' }, randomUUID());
  const db = getFirestore(app);
  const uid = `personalization-${randomUUID()}`;
  const cleanupUsers = [uid];
  const profile = db.doc(`users/${uid}/profile/data`);
  t.mock.method(firebase, 'getDb', () => db);
  t.mock.method(auth, 'verifyAppCheck', async () => true);
  t.mock.method(auth, 'requireAuth', async (req: Request) => Object.assign(req, { userId: uid }));
  // The legacy loader uses the default Firebase app. Only redirect its reads;
  // the real personalization helper and all endpoint transactions use this db.
  t.mock.method(profiles, 'getUserProfileOnce', async () => (await profile.get()).data());
  t.after(async () => {
    t.mock.restoreAll();
    for (const user of cleanupUsers) await deleteAllUserFirestoreData(db, user);
    await deleteApp(app);
  });
  return { db, uid, profile, cleanupUsers };
}

type Scenario = 'opted-in' | 'opted-out' | 'missing' | 'opt-in-mid-request' | 'before-agent' |
  'input-moderation' | 'generation-gate' | 'output-gate' | 'retry-backoff' |
  'base-revoked-at-generation-gate' | 'base-revoked-at-output-gate' |
  'generation' | 'output-moderation' | 'read-failure';

for (const kind of ['mood', 'reflection'] as const) {
  const scenarios: Scenario[] = ['opted-in', 'opted-out', 'missing', 'opt-in-mid-request', 'before-agent',
    'generation-gate', 'output-gate', 'retry-backoff', 'generation', 'output-moderation', 'read-failure'];
  scenarios.push('base-revoked-at-generation-gate', 'base-revoked-at-output-gate');
  if (kind === 'mood') scenarios.push('input-moderation');
  for (const scenario of scenarios) {
    test(`${kind}: personalization ${scenario}`, { skip: !hasEmulator, timeout: 15_000 }, async t => {
      const ready = deferred();
      const release = deferred();
      t.after(release.resolve);
      const { db, uid, profile } = fixture(t);
      const captures: Array<{ profile: UserProfilePayload | null }> = [];
      const moderated: string[] = [];
      async function pause() { ready.resolve(); await release.promise; }

      // Real moderation parsing and routing, without external HTTP or secrets.
      t.mock.method(globalThis, 'fetch', async (_url: string | URL | globalThis.Request, init?: RequestInit) => {
        const body = JSON.parse(String(init?.body)) as { input: string };
        moderated.push(body.input);
        if ((scenario === 'input-moderation' && body.input === note) ||
            (scenario === 'output-moderation' && body.input === generatedText)) await pause();
        return new globalThis.Response(JSON.stringify({ results: [{
          flagged: false,
          categories: { 'self-harm': false, 'self-harm/intent': false, 'self-harm/instructions': false },
        }] }), { status: 200 });
      });
      if (scenario === 'retry-backoff') t.mock.method(modelConfig, 'sleep', pause);
      if (scenario === 'read-failure') {
        t.mock.method(personalization, 'createAiPersonalization', async () => {
          throw new Error('Synthetic profile read failure');
        });
      }
      async function generate(serialized: string) {
        captures.push(JSON.parse(serialized) as { profile: UserProfilePayload | null });
        if (scenario === 'generation') await pause();
        if (scenario === 'retry-backoff' && captures.length === 1) throw new Error('Synthetic generation failure');
        // If permission was revoked in flight, this marker must never reach
        // output moderation. Other controls return ordinary, valid prose.
        const text = scenario === 'generation' || scenario === 'output-gate' ? 'SYNTHETIC_PROFILE_MAJOR' : generatedText;
        return kind === 'mood' ? { message: text, verseId: 'psalm_46_1' } : { reflection: text };
      }
      const realMood = moodAgent.runMoodAgent;
      const realReflection = reflectionAgent.runReflectionAgent;
      let stageChecks = 0;
      async function checkStage(check: Parameters<typeof realMood>[2]) {
        await check();
        stageChecks++;
        const generationStage = kind === 'mood' ? 2 : 1;
        if ((['generation-gate', 'base-revoked-at-generation-gate'].includes(scenario) && stageChecks === generationStage) ||
            (['output-gate', 'base-revoked-at-output-gate'].includes(scenario) && stageChecks === generationStage + 1)) await pause();
      }
      t.mock.method(moodAgent, 'runMoodAgent', async (...[input, _key, check, _model, _generate, beforeGeneration]: Parameters<typeof realMood>) => {
        if (scenario === 'before-agent' || scenario === 'opt-in-mid-request') await pause();
        return realMood(input, 'synthetic-key', () => checkStage(check), undefined, generate, beforeGeneration);
      });
      t.mock.method(reflectionAgent, 'runReflectionAgent', async (...[summaries, _key, check, receipt]: Parameters<typeof realReflection>) => {
        if (scenario === 'before-agent' || scenario === 'opt-in-mid-request') await pause();
        return realReflection(summaries, 'synthetic-key', () => checkStage(check), receipt, generate);
      });

      if (scenario !== 'missing') await profile.set({ ...profileData,
        optInTailored: scenario !== 'opted-out' && scenario !== 'opt-in-mid-request' });
      await savePrivacyConsent(db, uid, { aiSharing: true, noticeVersion: NOTICE_VERSION, ageGroup: '18+', expectedRevision: 0 });
      const pending = kind === 'mood'
        ? invoke(moodCheckIn, 'POST', { checkInType: 'morning', moodSpectrumData: {
          moodScore: 5, followUpScore: 2, emotionTags: ['Calm'], impactCategories: ['Work'], note,
        } })
        : invoke(dailyReflection, 'GET');
      if (['before-agent', 'opt-in-mid-request', 'input-moderation', 'generation-gate', 'output-gate',
        'base-revoked-at-generation-gate', 'base-revoked-at-output-gate',
        'retry-backoff', 'generation', 'output-moderation'].includes(scenario)) {
        await ready.promise;
        try {
          if (scenario.startsWith('base-revoked')) {
            await savePrivacyConsent(db, uid, { aiSharing: false });
          } else {
            assert.equal((await invoke(userProfile, 'PATCH', { optInTailored: scenario === 'opt-in-mid-request' })).status, 200);
          }
        } finally { release.resolve(); }
      }
      const result = await pending;
      const today = getLogicalDateString(scenario === 'missing' ? 'America/New_York' : 'UTC');
      const saved = await db.doc(`users/${uid}/${kind === 'mood' ? `moodCheckIns/${today}_morning` : `dailyReflections/${today}`}`).get();
      const budgets = await db.collection('_dailyBudgets').get();
      const charged = budgets.docs.filter(doc => doc.id.startsWith(`${uid}_`))
        .reduce((sum, doc) => sum + Number(doc.get('callCount')), 0);
      if (scenario.startsWith('base-revoked')) {
        assert.equal(result.status, 403);
        assert.match(JSON.stringify(result.payload), /AI_CONSENT_REQUIRED/);
        assert.equal(saved.exists, false);
        assert.equal(captures.length, scenario === 'base-revoked-at-generation-gate' ? 0 : 1);
        assert.deepEqual(moderated, kind === 'mood' ? [note] : []);
        assert.equal(charged, kind === 'mood' && captures.length > 0 ? 1 : 0);
        return;
      }
      if (scenario === 'read-failure') {
        assert.equal(result.status, 500);
        assert.equal(saved.exists, false);
        assert.deepEqual(captures, []);
        assert.deepEqual(moderated, []);
        assert.equal(charged, 0, 'failed permission reads must refund the reserved budget');
        return;
      }
      assert.equal(result.status, kind === 'mood' ? 201 : 200, JSON.stringify(result));
      assert.equal(saved.exists, true);
      assert.equal(charged, 1);
      assert.equal(captures.length, scenario === 'retry-backoff' ? 2 : 1);
      const shouldUseProfile = ['opted-in', 'generation', 'output-gate', 'output-moderation'].includes(scenario);
      assert.deepEqual(captures[captures.length - 1]?.profile, shouldUseProfile ? sanitizedProfile : null);
      if (scenario === 'retry-backoff') assert.deepEqual(captures[0].profile, sanitizedProfile);
      const stored = kind === 'mood' ? saved.get('aiResponse') : saved.data();
      if (scenario === 'generation' || scenario === 'output-gate' || scenario === 'output-moderation') {
        assert.equal(stored.isGenerated, false);
        assert.doesNotMatch(JSON.stringify(stored), /SYNTHETIC_PROFILE_MAJOR|Take a quiet moment today/);
        assert.doesNotMatch(JSON.stringify(result.payload), /SYNTHETIC_PROFILE_MAJOR|Take a quiet moment today/);
        if (scenario === 'generation' || scenario === 'output-gate') assert.deepEqual(moderated, kind === 'mood' ? [note] : []);
      } else {
        assert.equal(stored.isGenerated, true);
        assert.equal(kind === 'mood' ? stored.message : stored.reflection, generatedText);
        assert.ok(moderated.includes(generatedText));
      }
    });
  }
}

for (const kind of ['mood', 'reflection'] as const) {
  test(`${kind}: real SDK retry rebuilds without a revoked profile`, { skip: !hasEmulator }, async t => {
    const { db, uid, profile } = fixture(t);
    await profile.set(profileData);
    await savePrivacyConsent(db, uid, { aiSharing: true, noticeVersion: NOTICE_VERSION, ageGroup: '18+', expectedRevision: 0 });
    const requests: string[] = [];
    t.mock.method(modelConfig, 'sleep', async () => {});
    const realMood = moodAgent.runMoodAgent;
    const realReflection = reflectionAgent.runReflectionAgent;
    const key = `synthetic-${randomUUID()}`;
    t.mock.method(moodAgent, 'runMoodAgent', (...[input, _key, check, model, _generate, beforeGeneration]: Parameters<typeof realMood>) =>
      realMood(input, key, check, model, undefined, beforeGeneration));
    t.mock.method(reflectionAgent, 'runReflectionAgent', (...[summaries, _key, check, receipt]: Parameters<typeof realReflection>) =>
      realReflection(summaries, key, check, receipt));
    t.mock.method(globalThis, 'fetch', async (url: string | URL | globalThis.Request, options?: RequestInit) => {
      if (String(url).endsWith('/moderations')) return globalThis.Response.json({ results: [{
        flagged: false, categories: { 'self-harm': false, 'self-harm/intent': false, 'self-harm/instructions': false },
      }] });
      assert.ok(String(url).endsWith('/responses'));
      assert.equal(new Headers(options?.headers).get('x-stainless-retry-count'), '0', 'only guarded application retries are allowed');
      requests.push(String(options?.body));
      if (requests.length === 1) {
        assert.equal((await invoke(userProfile, 'PATCH', { optInTailored: false })).status, 200);
        return globalThis.Response.json({ error: { message: 'Synthetic retryable failure' } }, { status: 429 });
      }
      const output = kind === 'mood' ? { message: generatedText, verseId: 'psalm_46_1' } : { reflection: generatedText };
      return globalThis.Response.json({ id: 'synthetic', output: [{
        id: 'synthetic-message', type: 'message', role: 'assistant', status: 'completed',
        content: [{ type: 'output_text', text: JSON.stringify(output), annotations: [] }],
      }] });
    });
    const result = kind === 'mood'
      ? await invoke(moodCheckIn, 'POST', { checkInType: 'morning', moodSpectrumData: {
        moodScore: 5, followUpScore: 2, emotionTags: ['Calm'], impactCategories: ['Work'], note,
      } })
      : await invoke(dailyReflection, 'GET');
    assert.equal(result.status, kind === 'mood' ? 201 : 200, JSON.stringify(result));
    assert.equal(requests.length, 2);
    assert.match(requests[0], /SYNTHETIC_PROFILE_MAJOR/);
    assert.doesNotMatch(requests[1], /SYNTHETIC_PROFILE_MAJOR|SYNTHETIC_HOBBY|SYNTHETIC_OCCUPATION/);
    const today = getLogicalDateString('UTC');
    const saved = await db.doc(`users/${uid}/${kind === 'mood' ? `moodCheckIns/${today}_morning` : `dailyReflections/${today}`}`).get();
    assert.equal(kind === 'mood' ? saved.get('aiResponse.isGenerated') : saved.get('isGenerated'), true);
  });
}

for (const change of ['opt-out/regrant', 'PUT', 'DELETE/recreate', 'unrelated edit'] as const) {
  test(`profile receipt invalidates after real ${change}`, { skip: !hasEmulator }, async t => {
    const { db, uid, profile } = fixture(t);
    await profile.set(profileData);
    const receipt = await personalization.createAiPersonalization(db, uid, async () => {});
    const attempt = await receipt.forGeneration();
    assert.equal(await attempt.isCurrent(), true);
    assert.deepEqual(JSON.parse(JSON.stringify(attempt.profile)), sanitizedProfile);
    assert.equal(Object.isFrozen(attempt.profile), true);
    assert.equal(Object.isFrozen(attempt.profile?.hobbies), true);
    if (change === 'opt-out/regrant') {
      assert.equal((await invoke(userProfile, 'PATCH', { optInTailored: false })).status, 200);
      assert.equal((await invoke(userProfile, 'PATCH', { optInTailored: true })).status, 200);
    } else if (change === 'unrelated edit') {
      assert.equal((await invoke(userProfile, 'PATCH', { firstName: 'Another synthetic name' })).status, 200);
    } else {
      if (change === 'DELETE/recreate') assert.equal((await invoke(userProfile, 'DELETE')).status, 200);
      assert.equal((await invoke(userProfile, 'PUT', profileData)).status, 200);
    }
    assert.equal((await profile.get()).get('optInTailored'), true);
    assert.equal(await attempt.isCurrent(), false, 'a current true flag cannot revive an old snapshot');
    await db.runTransaction(async tx => {
      assert.equal(await receipt.isResultCurrent(tx), false);
    });
    assert.equal((await receipt.forGeneration()).profile, null);
    await db.runTransaction(async tx => {
      assert.equal(await receipt.isResultCurrent(tx), true, 'neutral retry output no longer depends on the old profile');
    });
    assert.deepEqual(JSON.parse(JSON.stringify((await (await personalization.createAiPersonalization(db, uid, async () => {})).forGeneration()).profile)), sanitizedProfile);
  });
}

test('permission reads fail closed, and another user cannot invalidate a receipt', { skip: !hasEmulator }, async t => {
  const { db, uid, profile, cleanupUsers } = fixture(t);
  const otherUid = `personalization-other-${randomUUID()}`;
  const otherProfile = db.doc(`users/${otherUid}/profile/data`);
  cleanupUsers.push(otherUid);
  await profile.set(profileData);
  await otherProfile.set(profileData);
  const first = await personalization.createAiPersonalization(db, uid, async () => {});
  const second = await personalization.createAiPersonalization(db, otherUid, async () => {});
  const attempt = await first.forGeneration();
  await otherProfile.update({ optInTailored: false });
  assert.equal((await second.forGeneration()).profile, null);
  assert.equal(await attempt.isCurrent(), true);
  const original = db.runTransaction;
  t.mock.method(db, 'runTransaction', async () => {
    throw new Error('Synthetic profile read outage');
  });
  await assert.rejects(attempt.isCurrent(), /Synthetic profile read outage/);
  await assert.rejects(first.forGeneration(), /Synthetic profile read outage/);
  // Cleanup needs working document reads.
  t.mock.restoreAll();
  assert.equal(db.runTransaction, original);
});
