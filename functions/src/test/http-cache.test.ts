import assert from 'node:assert/strict';
import test, { type TestContext } from 'node:test';
import type { Request } from 'firebase-functions/v2/https';
import type { Response } from 'express';
import firebase = require('../shared/firebase');
import profiles = require('../shared/profile');
import { errorResponse, requireAuth, successResponse } from '../shared/auth';
import { moodCheckIn } from '../api/mood-checkin';
import { journal } from '../api/journal';
import { dailyReflection } from '../api/daily-reflection';

function responseCapture() {
  const headers: Record<string, string> = {};
  let status = 0;
  let body: unknown;
  let sentHeaders: Record<string, string> = {};
  const response = {
    setHeader: (name: string, value: string) => { headers[name.toLowerCase()] = value; return response; },
    set: (name: string, value: string) => { headers[name.toLowerCase()] = value; return response; },
    status: (value: number) => { status = value; return response; },
    json: (value: unknown) => { body = value; sentHeaders = { ...headers }; return response; },
    send: () => { sentHeaders = { ...headers }; return response; },
  };
  return {
    response: response as unknown as Response,
    currentHeaders: () => ({ ...headers }),
    result: () => ({ status, body, headers: sentHeaders }),
  };
}

const syntheticEntry = { id: 'entry', text: 'Synthetic private journal text' };

function prepare(t: TestContext, options: { exhausted?: boolean; deleting?: boolean; unverified?: boolean } = {}) {
  const reads: string[] = [];
  const deletions: string[] = [];
  const snapshot = (path: string) => {
    reads.push(path);
    const data = path.startsWith('_accountDeletions/')
      ? (options.deleting ? { status: 'deleting' } : undefined)
      : path.startsWith('_rateLimits/') && options.exhausted
        ? { timestamps: Array(30).fill(new Date().toISOString()) }
        : path.endsWith('/journalEntries/entry') ? syntheticEntry : undefined;
    return { exists: data !== undefined, data: () => data };
  };
  const reference = (path: string) => ({
    path,
    collection: (name: string) => collection(`${path}/${name}`),
    get: async () => snapshot(path),
    delete: async () => { deletions.push(path); },
  });
  const collection = (path: string) => {
    const query = {
      doc: (id: string) => reference(`${path}/${id}`),
      where: () => query,
      orderBy: () => query,
      limit: () => query,
      get: async () => {
        reads.push(path);
        return { docs: path.endsWith('/journalEntries') ? [{ data: () => syntheticEntry }] : [] };
      },
    };
    return query;
  };
  const transaction = { get: async (ref: { path: string }) => snapshot(ref.path), set: () => {} };
  const db = {
    collection,
    doc: reference,
    runTransaction: async <T>(run: (tx: typeof transaction) => Promise<T>) => run(transaction),
  };
  t.mock.method(firebase, 'getDb', () => db);
  t.mock.method(firebase, 'getAuthInstance', () => ({ verifyIdToken: async (token: string, checkRevoked: boolean) => {
    assert.equal(token, 'synthetic-token');
    assert.equal(checkRevoked, true);
    return { uid: 'synthetic-user', firebase: { sign_in_provider: 'password' }, email_verified: !options.unverified };
  } }));
  t.mock.method(firebase, 'getAppCheckInstance', () => ({ verifyToken: async () => ({ appId: 'synthetic-app' }) }));
  t.mock.method(profiles, 'getUserProfileOnce', async () => ({ timezone: 'UTC' }));
  return { reads, deletions };
}

type Handler = (req: Request, res: Response) => void | Promise<void>;

async function invoke(handler: Handler, method: string, query: Record<string, string | string[]> = {}, headers = {
  authorization: 'Bearer synthetic-token', 'x-firebase-appcheck': 'synthetic-app-check',
}, path = '/entry') {
  const capture = responseCapture();
  await handler({ method, path, query, headers } as unknown as Request, capture.response);
  return capture.result();
}

function assertPrivate(result: ReturnType<ReturnType<typeof responseCapture>['result']>, status: number) {
  assert.equal(result.status, status);
  assert.equal(result.headers['cache-control'], 'private, no-store');
}

test('shared JSON responses prohibit storage without changing payload or status', () => {
  const success = responseCapture();
  const payload = { privateValue: 'synthetic' };
  successResponse(success.response, payload, 201);
  assertPrivate(success.result(), 201);
  assert.deepEqual(success.result().body, payload);

  const error = responseCapture();
  errorResponse(error.response, 403, 'Current consent required', undefined, 'AI_CONSENT_REQUIRED');
  assertPrivate(error.result(), 403);
  assert.deepEqual(error.result().body, { error: 'Forbidden', message: 'Current consent required', code: 'AI_CONSENT_REQUIRED' });
});

test('authentication applies cache policy before token verification yields', async t => {
  prepare(t);
  const capture = responseCapture();
  let policyDuringVerification: string | undefined;
  t.mock.method(firebase, 'getAuthInstance', () => ({ verifyIdToken: async () => {
    // Observe the header before verification returns or any response helper runs.
    policyDuringVerification = capture.currentHeaders()['cache-control'];
    throw new Error('Synthetic invalid token');
  } }));
  assert.equal(await requireAuth({ headers: { authorization: 'Bearer synthetic-token' } } as Request, capture.response), null);
  assert.equal(policyDuringVerification, 'private, no-store');
  assertPrivate(capture.result(), 401);
});

test('mood and journal reads retain owner-scoped responses with no-store', async t => {
  t.mock.timers.enable({ apis: ['Date'], now: new Date('2026-10-08T12:00:00Z') });
  const db = prepare(t);
  const mood = await invoke(moodCheckIn, 'GET', { fullHistory: '7' });
  assertPrivate(mood, 200);
  assert.deepEqual(mood.body, {
    checkIns: [], daysRequested: 7,
    windowStartDate: '2026-10-01', windowEndDate: '2026-10-08', hasMoreCheckIns: false,
  });
  const entries = await invoke(journal, 'GET');
  assertPrivate(entries, 200);
  assert.deepEqual(entries.body, { entries: [syntheticEntry] });
  assert.ok(db.reads.includes('users/synthetic-user/moodCheckIns'));
  assert.ok(db.reads.includes('users/synthetic-user/journalEntries'));
});

test('direct validation, quota, and deletion responses inherit the auth cache policy', async t => {
  await t.test('mood validation bypasses JSON helpers', async child => {
    prepare(child);
    assertPrivate(await invoke(moodCheckIn, 'GET', { history: 'invalid' }), 400);
  });
  await t.test('exhausted quota preserves Retry-After and error contract', async child => {
    prepare(child, { exhausted: true });
    const result = await invoke(moodCheckIn, 'GET');
    assertPrivate(result, 429);
    assert.ok(Number(result.headers['retry-after']) > 0);
    assert.equal((result.body as { code: string }).code, 'RATE_LIMITED');
  });
  await t.test('journal deletion preserves empty 204 and owner path', async child => {
    const db = prepare(child);
    const result = await invoke(journal, 'DELETE');
    assertPrivate(result, 204);
    assert.equal(result.body, undefined);
    assert.deepEqual(db.deletions, ['users/synthetic-user/journalEntries/entry']);
  });
});

test('early method/App Check failures and authenticated denials prohibit storage', async t => {
  prepare(t);
  assertPrivate(await invoke(moodCheckIn, 'GET', {}, { authorization: '', 'x-firebase-appcheck': '' }), 401);
  assertPrivate(await invoke(moodCheckIn, 'GET', {}, { authorization: '', 'x-firebase-appcheck': 'synthetic' }), 401);
  assertPrivate(await invoke(moodCheckIn, 'OPTIONS'), 405);
  await t.test('email verification denial', async child => {
    prepare(child, { unverified: true });
    assertPrivate(await invoke(journal, 'GET'), 403);
  });
  await t.test('account deletion barrier', async child => {
    prepare(child, { deleting: true });
    assertPrivate(await invoke(journal, 'GET'), 403);
  });
});

test('repeated or bracketed query params are rejected, not coerced', async t => {
  t.mock.timers.enable({ apis: ['Date'], now: new Date('2026-10-08T12:00:00Z') });
  const db = prepare(t);
  // ['2026-10-01'] passes a date regex by string coercion; it must still be refused.
  const moodQueries: Record<string, string | string[]>[] = [{ fullHistory: '7', startDate: ['2026-10-01'] },
    { history: ['7', '8'] }, { history: '7', endDate: ['2026-10-08'] }, { fullHistory: ['7'] }];
  for (const query of moodQueries) {
    assertPrivate(await invoke(moodCheckIn, 'GET', query), 400);
  }
  const journalQueries: Record<string, string | string[]>[] = [{ date: ['2026-10-08'] }, { limit: ['5', '6'] }];
  for (const query of journalQueries) {
    assertPrivate(await invoke(journal, 'GET', query), 400);
  }
  assert.ok(!db.reads.includes('users/synthetic-user/moodCheckIns'));
  assert.ok(!db.reads.includes('users/synthetic-user/moodSummaries'));
  assert.ok(!db.reads.includes('users/synthetic-user/journalEntries'));
});

test('a non-string reflection date falls back to the user\'s today', async t => {
  t.mock.timers.enable({ apis: ['Date'], now: new Date('2026-10-08T12:00:00Z') });
  const db = prepare(t);
  // Generation itself is not mocked here; only the cache key matters.
  await invoke(dailyReflection, 'GET', { date: ['2026-10-09'] });
  assert.ok(db.reads.includes('users/synthetic-user/dailyReflections/2026-10-08'));
  assert.ok(!db.reads.some(path => path.includes('dailyReflections/2026-10-09')));
});

test('journal deletion accepts only a single safe id segment', async t => {
  const db = prepare(t);
  for (const path of ['/a/b/c', '/..', '/entry%2Fx', '/' + 'a'.repeat(129)]) {
    assertPrivate(await invoke(journal, 'DELETE', {}, undefined, path), 400);
  }
  assert.deepEqual(db.deletions, []);
  // A UUID passes validation and reaches the owner-scoped lookup.
  assertPrivate(await invoke(journal, 'DELETE', {}, undefined, '/3f2b8c1e-9d4a-4e6b-8f1a-2c3d4e5f6a7b'), 404);
  assert.ok(db.reads.includes('users/synthetic-user/journalEntries/3f2b8c1e-9d4a-4e6b-8f1a-2c3d4e5f6a7b'));
});
