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

const scenarios = [
  'after-input', 'after-generation', 'during-backoff', 'before-persistence',
  'withdraw-and-regrant', 'consent-read-failure', 'account-deleting', 'provider-failure', 'success',
] as const;

// Real endpoints, agents, consent revisions, persistence and quota transactions;
// only auth, profile loading and the external providers are synthetic.
for (const endpoint of ['mood', 'reflection'] as const) {
  for (const scenario of scenarios) {
    if (endpoint === 'reflection' && scenario === 'after-input') continue;
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
      let generations = 0;
      let moderations = 0;
      let denyReads = false;
      let backoffs = 0;
      const withdraw = () => consent.savePrivacyConsent(db, uid, { aiSharing: false });
      t.mock.method(firebase, 'getDb', () => db);
      t.mock.method(auth, 'verifyAppCheck', async () => true);
      t.mock.method(auth, 'requireAuth', async (req: Request) => Object.assign(req, { userId: uid }));
      t.mock.method(profile, 'getUserProfileOnce', async () => ({ timezone: 'UTC', optInTailored: false }));
      t.mock.method(consent, 'requireAiConsent', async (...args: Parameters<typeof realRequireConsent>) => {
        if (denyReads) throw new TypeError('Synthetic consent read failure');
        return realRequireConsent(...args);
      });
      t.mock.method(config, 'sleep', async () => {
        backoffs++;
        if (scenario === 'during-backoff') await withdraw();
      });
      const generate = async () => {
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
      t.mock.method(reflectionAgent, 'runReflectionAgent', (...[summaries, _key, check, userProfile]: Parameters<typeof realReflection>) =>
        realReflection(summaries, 'synthetic-key', check, userProfile, generate));
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
        const result = await invoke();
        const expectedStatus = scenario === 'success' ? (endpoint === 'mood' ? 201 : 200)
          : scenario === 'provider-failure' || scenario === 'consent-read-failure' ? 500 : 403;
        assert.equal(result.status, expectedStatus, JSON.stringify(result));
        if (expectedStatus === 403) {
          assert.equal(result.body.code, scenario === 'account-deleting' ? 'ACCOUNT_DELETING' : 'AI_CONSENT_REQUIRED');
        }
        assert.equal(generations, scenario === 'after-input' ? 0 : scenario === 'provider-failure' ? 2 : 1);
        assert.equal(backoffs, scenario === 'during-backoff' || scenario === 'provider-failure' ? 1 : 0);
        assert.equal(moderations, (endpoint === 'mood' ? 1 : 0) +
          (scenario === 'success' || scenario === 'before-persistence' ? 1 : 0));
        const today = getLogicalDateString('UTC');
        const target = endpoint === 'mood' ? `moodCheckIns/${today}_morning` : `dailyReflections/${today}`;
        assert.equal((await db.doc(`users/${uid}/${target}`).get()).exists, scenario === 'success');
        if (endpoint === 'mood') {
          assert.equal((await db.doc(`users/${uid}/moodSummaries/${today}`).get()).exists, scenario === 'success');
        }
        const budgets = (await db.collection('_dailyBudgets').get()).docs.filter(doc => doc.id.startsWith(`${uid}_`));
        assert.equal(refund.mock.callCount(), endpoint === 'mood' || scenario === 'success' ? 0 : 1);
        // Mood claims refund only proven unconsumed work. Reflection retains
        // its existing accounting; deletion barriers block its refund writes.
        assert.equal(budgets.reduce((sum, doc) => sum + Number(doc.get('callCount')), 0),
          endpoint === 'mood' ? (generations > 0 ? 1 : 0)
            : scenario === 'success' || scenario === 'account-deleting' ? 1 : 0);
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
