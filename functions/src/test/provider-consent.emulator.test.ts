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
import consent = require('../shared/privacy-consent');
import limits = require('../shared/rate-limiter');
import moodAgent = require('../lib/mood-agent');
import reflectionAgent = require('../lib/reflection-agent');
import config = require('../lib/model-config');
import { moodCheckIn } from '../api/mood-checkin';
import { dailyReflection } from '../api/daily-reflection';
import { deletionRef } from '../shared/account-lifecycle';
import { deleteAllUserFirestoreData } from '../shared/account-deletion';
import { getLogicalDateString } from '../shared/time';

// A legacy opted-in profile: none of it may ever reach the model.
const legacyProfile = {
  timezone: 'UTC', optInTailored: true, ageRange: '18-24' as const, firstName: 'SYNTHETIC_NAME',
  major: 'SYNTHETIC_MAJOR', occupation: 'SYNTHETIC_OCCUPATION', hobbies: ['Music', 'SYNTHETIC_HOBBY'],
};

const scenarios = [
  'after-input', 'after-generation', 'during-backoff', 'before-persistence',
  'withdraw-and-regrant', 'consent-read-failure', 'account-deleting', 'provider-failure', 'success',
  'before-dispatch',
] as const;

// Real endpoints, agents, consent revisions, persistence and quota transactions;
// only auth, profile loading and the external providers are synthetic.
for (const endpoint of ['mood', 'reflection'] as const) {
  for (const scenario of scenarios) {
    if (endpoint === 'reflection' && scenario === 'after-input') continue;
    if (endpoint === 'mood' && scenario === 'before-dispatch') continue;
    test(`${endpoint}: ${scenario} preserves consent errors, writes and budget accounting`, {
      skip: !process.env.FIRESTORE_EMULATOR_HOST,
    }, async t => {
      const app = initializeApp({ projectId: 'demo-walkworthy-compliance' }, randomUUID());
      const db = getFirestore(app);
      const uid = `provider-consent-${randomUUID()}`;
      const realMood = moodAgent.runMoodAgent;
      const realReflection = reflectionAgent.runReflectionAgent;
      const realRequireConsent = consent.requireAiConsent;
      const refund = t.mock.method(limits, 'refundDailyAiBudget');
      // A pre-dispatch failure whose refund runs after UTC midnight must not
      // touch the next day's counter.
      const nextDay = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
      let generations = 0;
      let moderations = 0;
      let denyReads = false;
      let backoffs = 0;
      const modelInputs: string[] = [];
      const withdraw = () => consent.savePrivacyConsent(db, uid, { aiSharing: false });
      t.mock.method(firebase, 'getDb', () => db);
      t.mock.method(auth, 'verifyAppCheck', async () => true);
      t.mock.method(auth, 'requireAuth', async (req: Request) => Object.assign(req, { userId: uid }));
      t.mock.method(profile, 'getUserProfileOnce', async () => legacyProfile);
      t.mock.method(consent, 'requireAiConsent', async (...args: Parameters<typeof realRequireConsent>) => {
        if (denyReads) throw new TypeError('Synthetic consent read failure');
        if (scenario === 'before-dispatch') t.mock.method(limits, 'getTodayUtcDateString', () => nextDay);
        return realRequireConsent(...args);
      });
      t.mock.method(config, 'sleep', async () => {
        backoffs++;
        if (scenario === 'during-backoff') await withdraw();
      });
      const generate = async (serialized: string) => {
        modelInputs.push(serialized);
        generations++;
        if (scenario === 'during-backoff' || scenario === 'provider-failure') {
          throw new Error('Synthetic provider failure');
        }
        if (scenario === 'after-generation') await withdraw();
        if (scenario === 'withdraw-and-regrant') {
          const revoked = await withdraw();
          await consent.savePrivacyConsent(db, uid, {
            aiSharing: true, noticeVersion: consent.NOTICE_VERSION, ageGroup: '18+',
            expectedRevision: revoked.revision,
          });
        }
        if (scenario === 'consent-read-failure') denyReads = true;
        if (scenario === 'account-deleting') await deletionRef(db, uid).set({ status: 'deleting' });
        return endpoint === 'mood'
          ? { message: 'Take a quiet moment today.', verseId: 'psalm_46_1' }
          : { reflection: 'Take a quiet moment today.' };
      };
      t.mock.method(moodAgent, 'runMoodAgent', (...[input, _key, check, model, _generate, beforeGeneration]: Parameters<typeof realMood>) =>
        realMood(input, 'synthetic-key', check, model, generate, beforeGeneration));
      t.mock.method(reflectionAgent, 'runReflectionAgent', (...[summaries, _key, check, _generate, beforeGeneration]: Parameters<typeof realReflection>) =>
        realReflection(summaries, 'synthetic-key', check, generate, beforeGeneration));
      t.mock.method(globalThis, 'fetch', async (url: string | URL | globalThis.Request) => {
        assert.ok(String(url).endsWith('/moderations'), 'Only synthetic moderation transport is expected');
        moderations++;
        if (scenario === 'after-input' || (scenario === 'before-persistence' &&
            moderations === (endpoint === 'mood' ? 2 : 1))) await withdraw();
        return globalThis.Response.json({ results: [{ flagged: false, categories: {
          'self-harm': false, 'self-harm/intent': false, 'self-harm/instructions': false,
        } }] });
      });
      async function invoke() {
        let status = 200;
        let body: Record<string, unknown> = {};
        const response = {
          setHeader: () => response, set: () => response,
          status: (value: number) => { status = value; return response; },
          json: (value: Record<string, unknown>) => { body = value; return response; },
        };
        const request = { method: endpoint === 'mood' ? 'POST' : 'GET', query: {}, body: {
          checkInType: 'morning', moodSpectrumData: {
            moodScore: 5, followUpScore: 3, emotionTags: ['Calm'],
            impactCategories: [], note: 'Synthetic check-in',
          },
        } } as unknown as Request;
        await (endpoint === 'mood' ? moodCheckIn : dailyReflection)(request, response as unknown as Response);
        return { status, body };
      }
      try {
        await consent.savePrivacyConsent(db, uid, {
          aiSharing: true, noticeVersion: consent.NOTICE_VERSION, ageGroup: '18+', expectedRevision: 0,
        });
        await db.doc(`users/${uid}/profile/data`).set(legacyProfile);
        if (scenario === 'before-dispatch') {
          await db.doc(`_dailyBudgets/${uid}_${nextDay}`).set({ callCount: 1, date: nextDay });
          await withdraw();
        }
        const result = await invoke();
        for (const sent of modelInputs) {
          assert.equal('profile' in JSON.parse(sent), false);
          assert.doesNotMatch(sent, /SYNTHETIC_|18-24/);
        }
        const expectedStatus = scenario === 'success' ? (endpoint === 'mood' ? 201 : 200)
          : scenario === 'provider-failure' || scenario === 'consent-read-failure' ? 500 : 403;
        assert.equal(result.status, expectedStatus, JSON.stringify(result));
        if (expectedStatus === 403) {
          assert.equal(result.body.code, scenario === 'account-deleting' ? 'ACCOUNT_DELETING' : 'AI_CONSENT_REQUIRED');
        }
        assert.equal(generations, scenario === 'after-input' || scenario === 'before-dispatch' ? 0
          : scenario === 'provider-failure' ? 2 : 1);
        assert.equal(backoffs, scenario === 'during-backoff' || scenario === 'provider-failure' ? 1 : 0);
        assert.equal(moderations, (endpoint === 'mood' ? 1 : 0) +
          (scenario === 'success' || scenario === 'before-persistence' ? 1 : 0));
        const today = getLogicalDateString('UTC');
        const target = endpoint === 'mood' ? `moodCheckIns/${today}_morning` : `dailyReflections/${today}`;
        assert.equal((await db.doc(`users/${uid}/${target}`).get()).exists, scenario === 'success');
        if (endpoint === 'mood') {
          assert.equal((await db.doc(`users/${uid}/moodSummaries/${today}`).get()).exists, scenario === 'success');
        }
        const budgets = (await db.collection('_dailyBudgets').get()).docs
          .filter(doc => doc.id.startsWith(`${uid}_`) && doc.id !== `${uid}_${nextDay}`);
        // Both endpoints refund only proven undispatched work: a consent change,
        // provider failure or write failure after dispatch keeps the charge.
        assert.equal(refund.mock.callCount(), endpoint === 'reflection' && generations === 0 ? 1 : 0);
        assert.equal(budgets.reduce((sum, doc) => sum + Number(doc.get('callCount')), 0), generations > 0 ? 1 : 0);
        if (scenario === 'before-dispatch') {
          assert.equal(refund.mock.calls[0].arguments[2], budgets[0].get('date'));
          assert.equal((await db.doc(`_dailyBudgets/${uid}_${nextDay}`).get()).get('callCount'), 1);
        }
        if (endpoint === 'mood') {
          const claims = await db.collection(`users/${uid}/moodGenerationClaims`).get();
          assert.equal(claims.size, 1);
          assert.equal(claims.docs[0].get('consumed'), generations > 0);
          if (scenario !== 'account-deleting') {
            assert.equal(claims.docs[0].get('status'), scenario === 'success' ? 'completed' : 'failed');
          }
        }
        if (scenario === 'success') {
          // Previously saved content stays readable without a new provider request.
          await withdraw();
          assert.equal((await invoke()).status, 200);
          assert.equal(generations, 1);
          assert.equal(moderations, endpoint === 'mood' ? 2 : 1);
        }
      } finally {
        t.mock.restoreAll();
        await deleteAllUserFirestoreData(db, uid);
        await deletionRef(db, uid).delete();
        await deleteApp(app);
      }
    });
  }
}
