import assert from 'node:assert/strict';
import test, { type TestContext } from 'node:test';
import type { Request } from 'firebase-functions/v2/https';
import type { Response } from 'express';
import firebase = require('../shared/firebase');
import authMiddleware = require('../shared/auth');
import limits = require('../shared/rate-limiter');
import profiles = require('../shared/profile');
import moodAgent = require('../lib/mood-agent');
import reflectionAgent = require('../lib/reflection-agent');
import { moodCheckIn } from '../api/mood-checkin';
import { dailyReflection } from '../api/daily-reflection';
import { journal } from '../api/journal';
import { userProfile } from '../api/user-profile';
import { privacyConsent, PRIVACY_CONSENT_READ_LIMIT } from '../api/privacy-consent';
import { NOTICE_VERSION } from '../shared/privacy-consent';

type Outcome = 'unavailable' | 'accountDeleting' | 'exhausted';
type Endpoint = {
  name: string;
  handler: (req: Request, res: Response) => void | Promise<void>;
  method: string;
  body?: Record<string, unknown>;
};

const moodPost: Endpoint = {
  name: 'mood POST', handler: moodCheckIn, method: 'POST',
  body: {
    checkInType: 'morning',
    moodSpectrumData: {
      moodScore: 5, moodLevel: 'neutral', emotionTags: ['Calm'],
      impactCategories: [], followUpScore: 3, note: 'Synthetic note',
    },
  },
};
const reflectionGet: Endpoint = { name: 'reflection GET', handler: dailyReflection, method: 'GET' };
const endpoints: Endpoint[] = [
  { name: 'mood GET', handler: moodCheckIn, method: 'GET' },
  moodPost,
  reflectionGet,
  { name: 'journal DELETE', handler: journal, method: 'DELETE' },
  { name: 'profile PATCH', handler: userProfile, method: 'PATCH', body: { firstName: 'Synthetic' } },
  { name: 'consent GET', handler: privacyConsent, method: 'GET' },
  {
    name: 'consent grant', handler: privacyConsent, method: 'PUT',
    body: { aiSharing: true, noticeVersion: NOTICE_VERSION, ageGroup: '18+', expectedRevision: 0 },
  },
];

// Run real limiter transactions against controlled snapshots. Missing user data
// keeps both AI endpoints on their generation path until the budget gate.
function database(target: '_rateLimits' | '_dailyBudgets', outcome: Outcome) {
  const reads: string[] = [];
  const writes: string[] = [];
  const snapshot = (path: string) => {
    reads.push(path);
    if (path.startsWith(`${target}/`)) {
      if (outcome === 'unavailable') throw new Error('Synthetic transaction read failure');
      const data = target === '_rateLimits'
        ? { timestamps: Array(PRIVACY_CONSENT_READ_LIMIT.maxRequests).fill(new Date().toISOString()) }
        : { callCount: 99, date: limits.getTodayUtcDateString() };
      return { exists: true, data: () => data };
    }
    return {
      exists: path.startsWith('_accountDeletions/') && outcome === 'accountDeleting',
      data: () => undefined,
    };
  };
  const reference = (path: string) => ({
    path,
    collection: (name: string) => collection(`${path}/${name}`),
    get: async () => snapshot(path),
    set: async () => { writes.push(path); },
    delete: async () => { writes.push(path); },
  });
  const collection = (path: string) => {
    const query = {
      doc: (id: string) => reference(`${path}/${id}`),
      where: () => query,
      orderBy: () => query,
      limit: () => query,
      get: async () => ({ docs: [] }),
    };
    return query;
  };
  const tx = {
    get: async (ref: { path: string }) => snapshot(ref.path),
    set: (ref: { path: string }) => { writes.push(ref.path); },
    update: (ref: { path: string }) => { writes.push(ref.path); },
    delete: (ref: { path: string }) => { writes.push(ref.path); },
  };
  return {
    reads, writes,
    collection,
    doc: reference,
    runTransaction: async <T>(run: (transaction: typeof tx) => Promise<T>) => run(tx),
  };
}

function prepare(t: TestContext, db: ReturnType<typeof database>) {
  t.mock.method(firebase, 'getDb', () => db);
  // Authentication succeeds before the quota transaction observes its failure
  // or a deletion barrier created concurrently with this request.
  t.mock.method(authMiddleware, 'verifyAppCheck', async () => true);
  t.mock.method(authMiddleware, 'requireAuth', async () => ({ userId: 'synthetic' }));
  t.mock.method(profiles, 'getUserProfileOnce', async () => undefined);
  const mood = t.mock.method(moodAgent, 'runMoodAgent', async () => {
    throw new Error('Generation must not run');
  });
  const reflection = t.mock.method(reflectionAgent, 'runReflectionAgent', async () => {
    throw new Error('Generation must not run');
  });
  return () => {
    assert.equal(mood.mock.callCount(), 0);
    assert.equal(reflection.mock.callCount(), 0);
    assert.deepEqual(db.writes, []);
  };
}

async function invoke(endpoint: Endpoint) {
  let status = 0;
  let body: Record<string, unknown> = {};
  const headers: Record<string, string> = {};
  const response = {
    setHeader: (key: string, value: string | number) => { headers[key.toLowerCase()] = String(value); return response; },
    set: (key: string, value: string | number) => { headers[key.toLowerCase()] = String(value); return response; },
    status: (value: number) => { status = value; return response; },
    json: (value: Record<string, unknown>) => { body = value; return response; },
  };
  await endpoint.handler({
    method: endpoint.method, body: endpoint.body, path: '/synthetic-entry', query: {},
    headers: { authorization: 'Bearer synthetic' },
  } as Request, response as unknown as Response);
  return { status, body, headers };
}

function assertDenied(result: Awaited<ReturnType<typeof invoke>>, outcome: Outcome, scope: 'user' | 'dailyBudget') {
  assert.equal(result.status, outcome === 'unavailable' ? 503 : outcome === 'accountDeleting' ? 403 : 429);
  if (outcome === 'unavailable') {
    assert.equal(result.headers['retry-after'], '60');
    assert.notEqual(result.body.code, 'RATE_LIMITED');
  } else if (outcome === 'accountDeleting') {
    assert.equal(result.body.code, 'ACCOUNT_DELETING');
  } else {
    assert.equal(result.body.code, 'RATE_LIMITED');
    assert.equal(result.body.scope, scope);
    if (scope === 'user') assert.ok(Number(result.headers['retry-after']) > 0);
  }
}

test('hourly gates distinguish unavailable storage, concurrent deletion, and real exhaustion', async t => {
  for (const endpoint of endpoints) {
    for (const outcome of ['unavailable', 'accountDeleting', 'exhausted'] as const) {
      await t.test(`${endpoint.name}: ${outcome}`, async child => {
        const db = database('_rateLimits', outcome);
        const assertNoSideEffects = prepare(child, db);
        assertDenied(await invoke(endpoint), outcome, 'user');
        assert.ok(db.reads.some(path => path.startsWith('_accountDeletions/')));
        assertNoSideEffects();
      });
    }
  }
});

test('daily AI gates preserve failure classification and stop both generation paths', async t => {
  for (const endpoint of [moodPost, reflectionGet]) {
    for (const outcome of ['unavailable', 'accountDeleting', 'exhausted'] as const) {
      await t.test(`${endpoint.name}: ${outcome}`, async child => {
        const db = database('_dailyBudgets', outcome);
        const assertNoSideEffects = prepare(child, db);
        // Isolate the daily gate after a successful hourly admission.
        child.mock.method(limits, 'checkRateLimit', async () => ({ allowed: true, retryAfterSeconds: 0 }));
        assertDenied(await invoke(endpoint), outcome, 'dailyBudget');
        assert.ok(db.reads.some(path => path.startsWith(outcome === 'accountDeleting' ? '_accountDeletions/' : '_dailyBudgets/')));
        assertNoSideEffects();
      });
    }
  }
});
