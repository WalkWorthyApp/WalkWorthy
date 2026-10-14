import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Response } from 'express';
import type { Request } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';
import firebase = require('../shared/firebase');
import auth = require('../shared/auth');
import limiter = require('../shared/rate-limiter');
import suggestionStore = require('../shared/suggestion');
import { suggestion } from '../api/suggestion';
import { SUGGESTION_MAX_LENGTH, validateSuggestionInput } from '../shared/suggestion';

const valid = { id: 'ABCDEFAB-0000-4000-8000-000000000000', category: 'idea', text: '  Add a dark mode  ', appVersion: 'v1.2 (34)' };

test('valid suggestions are trimmed and normalized', () => {
  assert.deepEqual(validateSuggestionInput(valid), {
    id: valid.id.toLowerCase(), category: 'idea', text: 'Add a dark mode', appVersion: 'v1.2 (34)',
  });
  const { appVersion: _omit, ...withoutVersion } = valid;
  assert.equal('appVersion' in (validateSuggestionInput(withoutVersion) ?? {}), false);
});

test('length is counted in code points so emoji match the app counter', () => {
  assert.ok(validateSuggestionInput({ ...valid, text: '🙂'.repeat(SUGGESTION_MAX_LENGTH) }));
  assert.equal(validateSuggestionInput({ ...valid, text: 'a'.repeat(SUGGESTION_MAX_LENGTH + 1) }), null);
});

test('malformed suggestions are rejected', () => {
  for (const body of [null, [], 'text', {}]) assert.equal(validateSuggestionInput(body), null);
  for (const patch of [
    { id: 'not-a-uuid' }, { id: 1 }, { category: 'bug' }, { category: undefined },
    { text: '' }, { text: '   \n ' }, { text: 7 }, { appVersion: '' }, { appVersion: 'x'.repeat(33) },
    { appVersion: '<script>' }, { extra: true },
  ]) {
    assert.equal(validateSuggestionInput({ ...valid, ...patch }), null, JSON.stringify(patch));
  }
});

function fakeResponse() {
  const captured: { status: number; payload: unknown; headers: Record<string, string> } = { status: 200, payload: undefined, headers: {} };
  const response = {
    setHeader: (key: string, value: string) => { captured.headers[key] = value; return response; },
    set: (key: string, value: string) => { captured.headers[key] = value; return response; },
    status: (value: number) => { captured.status = value; return response; },
    json: (value: unknown) => { captured.payload = value; return response; },
  };
  return { response: response as unknown as Response, captured };
}

test('only POST is accepted', async () => {
  const { response, captured } = fakeResponse();
  await suggestion({ method: 'GET' } as Request, response);
  assert.equal(captured.status, 405);
  assert.equal(captured.headers.Allow, 'POST');
});

test('invalid bodies are rejected before spending rate-limit quota', async t => {
  t.mock.method(auth, 'verifyAppCheck', async () => true);
  t.mock.method(auth, 'requireAuth', async (req: Request) => Object.assign(req, { userId: 'synthetic' }));
  const limit = t.mock.method(limiter, 'checkRateLimit', async () => ({ allowed: true, retryAfterSeconds: 0 }));
  const { response, captured } = fakeResponse();
  await suggestion({ method: 'POST', body: { ...valid, text: '' } } as Request, response);
  assert.equal(captured.status, 400);
  assert.equal(limit.mock.callCount(), 0);
});

test('save failures never log or echo the suggestion text', async t => {
  t.mock.method(firebase, 'getDb', () => ({}));
  t.mock.method(auth, 'verifyAppCheck', async () => true);
  t.mock.method(auth, 'requireAuth', async (req: Request) => Object.assign(req, { userId: 'synthetic' }));
  t.mock.method(limiter, 'checkRateLimit', async () => ({ allowed: true, retryAfterSeconds: 0 }));
  t.mock.method(suggestionStore, 'saveSuggestion', async () => {
    throw new TypeError('PRIVATE_SENTINEL: synthetic suggestion text');
  });
  const errorLog = t.mock.method(logger, 'error', () => {});
  const { response, captured } = fakeResponse();
  await suggestion({ method: 'POST', body: { ...valid, text: 'PRIVATE_SENTINEL' } } as Request, response);
  assert.equal(captured.status, 503);
  assert.deepEqual(errorLog.mock.calls.map(call => call.arguments), [
    ['Suggestion save failed', { errorKind: 'TypeError' }],
  ]);
  assert.doesNotMatch(JSON.stringify(captured.payload), /PRIVATE_SENTINEL/);
});
