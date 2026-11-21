import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Response } from 'express';
import type { Request } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';
import firebase = require('../shared/firebase');
import auth = require('../shared/auth');
import limiter = require('../shared/rate-limiter');
import emailVerification = require('../shared/email-verification');
import { sendVerificationCode, verifyEmailCode } from '../api/email-verification';
import { generateCode, validateCodeInput, sendCodeEmail, EmailSendError } from '../shared/email-verification';

test('generated codes are always six digits', () => {
  for (let i = 0; i < 500; i++) assert.match(generateCode(), /^[0-9]{6}$/);
});

test('code input accepts only a six-digit code', () => {
  assert.equal(validateCodeInput({ code: '012345' }), '012345');
  assert.equal(validateCodeInput({ code: ' 012345 ' }), '012345');
  for (const body of [null, [], 'x', {}, { code: 12345 }, { code: '12345' }, { code: '1234567' },
    { code: '12a456' }, { code: '012345', extra: true }]) {
    assert.equal(validateCodeInput(body), null, JSON.stringify(body));
  }
});

test('the email names the code in the subject and body and keeps the key in the header', async t => {
  const fetchMock = t.mock.method(globalThis, 'fetch', async () => new Response('{}', { status: 200 }));
  await sendCodeEmail('key-123', 'WalkWorthy <verify@example.com>', 'user@example.com', '042042');
  const [url, init] = fetchMock.mock.calls[0].arguments as [string, RequestInit];
  assert.equal(url, 'https://api.resend.com/emails');
  assert.equal((init.headers as Record<string, string>).Authorization, 'Bearer key-123');
  const body = JSON.parse(init.body as string);
  assert.deepEqual(body.to, ['user@example.com']);
  assert.match(body.subject, /042042/);
  assert.match(body.text, /042042/);
  assert.doesNotMatch(init.body as string, /key-123/);
});

test('provider failures surface as EmailSendError without provider text', async t => {
  t.mock.method(globalThis, 'fetch', async () => new Response('PROVIDER_DETAIL', { status: 422 }));
  await assert.rejects(sendCodeEmail('k', 'f', 't', '000000'), (e: unknown) =>
    e instanceof EmailSendError && e.status === 422 && !e.message.includes('PROVIDER_DETAIL'));
  t.mock.method(globalThis, 'fetch', async () => { throw new TypeError('network down'); });
  await assert.rejects(sendCodeEmail('k', 'f', 't', '000000'), EmailSendError);
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

const passwordUser = (verified: boolean) => ({ firebase: { sign_in_provider: 'password' }, email_verified: verified });

function signedIn(t: import('node:test').TestContext, user: object, authUser: { email?: string; emailVerified: boolean }) {
  t.mock.method(firebase, 'getDb', () => ({}));
  t.mock.method(auth, 'verifyAppCheck', async () => true);
  t.mock.method(auth, 'requireAuth', async (req: Request, _res: Response, options?: { allowUnverified?: boolean }) => {
    assert.equal(options?.allowUnverified, true);
    return Object.assign(req, { userId: 'synthetic', user });
  });
  const updateUser = t.mock.fn(async () => ({}));
  t.mock.method(firebase, 'getAuthInstance', () => ({ getUser: async () => authUser, updateUser }));
  return { updateUser };
}

test('only POST is accepted', async () => {
  for (const handler of [sendVerificationCode, verifyEmailCode]) {
    const { response, captured } = fakeResponse();
    await handler({ method: 'GET' } as Request, response);
    assert.equal(captured.status, 405);
    assert.equal(captured.headers.Allow, 'POST');
  }
});

test('sending skips accounts that are already verified or not password accounts', async t => {
  for (const user of [passwordUser(true), { firebase: { sign_in_provider: 'apple.com' } }]) {
    signedIn(t, user, { email: 'a@example.com', emailVerified: true });
    const store = t.mock.method(emailVerification, 'storeCode', async () => {});
    const { response, captured } = fakeResponse();
    await sendVerificationCode({ method: 'POST', body: {} } as Request, response);
    assert.equal(captured.status, 200);
    assert.deepEqual(captured.payload, { sent: false, alreadyVerified: true });
    assert.equal(store.mock.callCount(), 0);
    t.mock.restoreAll();
  }
});

test('a rate-limited send stores and emails nothing', async t => {
  signedIn(t, passwordUser(false), { email: 'a@example.com', emailVerified: false });
  t.mock.method(limiter, 'checkRateLimit', async () => ({ allowed: false, retryAfterSeconds: 600 }));
  const store = t.mock.method(emailVerification, 'storeCode', async () => {});
  const send = t.mock.method(emailVerification, 'sendCodeEmail', async () => {});
  t.mock.method(logger, 'warn', () => {});
  const { response, captured } = fakeResponse();
  await sendVerificationCode({ method: 'POST', body: {} } as Request, response);
  assert.equal(captured.status, 429);
  assert.equal(store.mock.callCount(), 0);
  assert.equal(send.mock.callCount(), 0);
});

test('a send failure is a 503 and never logs or returns the code', async t => {
  signedIn(t, passwordUser(false), { email: 'a@example.com', emailVerified: false });
  t.mock.method(limiter, 'checkRateLimit', async () => ({ allowed: true, retryAfterSeconds: 0 }));
  t.mock.method(emailVerification, 'generateCode', () => '777111');
  t.mock.method(emailVerification, 'storeCode', async () => {});
  t.mock.method(emailVerification, 'sendCodeEmail', async () => { throw new EmailSendError(500); });
  const errorLog = t.mock.method(logger, 'error', () => {});
  const infoLog = t.mock.method(logger, 'info', () => {});
  const { response, captured } = fakeResponse();
  await sendVerificationCode({ method: 'POST', body: {} } as Request, response);
  assert.equal(captured.status, 503);
  const logged = JSON.stringify([...errorLog.mock.calls, ...infoLog.mock.calls].map(c => c.arguments));
  assert.doesNotMatch(logged, /777111/);
  assert.doesNotMatch(JSON.stringify(captured.payload), /777111/);
});

test('a malformed code is rejected before spending rate-limit quota', async t => {
  signedIn(t, passwordUser(false), { email: 'a@example.com', emailVerified: false });
  const limit = t.mock.method(limiter, 'checkRateLimit', async () => ({ allowed: true, retryAfterSeconds: 0 }));
  const { response, captured } = fakeResponse();
  await verifyEmailCode({ method: 'POST', body: { code: 'abc' } } as Request, response);
  assert.equal(captured.status, 400);
  assert.equal(limit.mock.callCount(), 0);
});

test('a correct code marks the Auth user verified', async t => {
  const { updateUser } = signedIn(t, passwordUser(false), { email: 'a@example.com', emailVerified: false });
  t.mock.method(limiter, 'checkRateLimit', async () => ({ allowed: true, retryAfterSeconds: 0 }));
  t.mock.method(emailVerification, 'checkCode', async () => 'verified');
  const { response, captured } = fakeResponse();
  await verifyEmailCode({ method: 'POST', body: { code: '123456' } } as Request, response);
  assert.equal(captured.status, 200);
  assert.deepEqual(captured.payload, { verified: true });
  assert.deepEqual(updateUser.mock.calls[0].arguments, ['synthetic', { emailVerified: true }]);
});

test('a wrong, expired or exhausted code is a 400 and leaves the user unverified', async t => {
  for (const outcome of ['invalid', 'expired', 'tooManyAttempts'] as const) {
    const { updateUser } = signedIn(t, passwordUser(false), { email: 'a@example.com', emailVerified: false });
    t.mock.method(limiter, 'checkRateLimit', async () => ({ allowed: true, retryAfterSeconds: 0 }));
    t.mock.method(emailVerification, 'checkCode', async () => outcome);
    t.mock.method(logger, 'info', () => {});
    const { response, captured } = fakeResponse();
    await verifyEmailCode({ method: 'POST', body: { code: '123456' } } as Request, response);
    assert.equal(captured.status, 400, outcome);
    assert.equal(typeof (captured.payload as { message: unknown }).message, 'string');
    assert.equal(updateUser.mock.callCount(), 0);
    t.mock.restoreAll();
  }
});

test('an account verified elsewhere succeeds even with a stale token', async t => {
  const { updateUser } = signedIn(t, passwordUser(false), { email: 'a@example.com', emailVerified: true });
  const clear = t.mock.method(emailVerification, 'clearCode', async () => {});
  const check = t.mock.method(emailVerification, 'checkCode', async () => 'invalid');
  const { response, captured } = fakeResponse();
  await verifyEmailCode({ method: 'POST', body: { code: '123456' } } as Request, response);
  assert.equal(captured.status, 200);
  assert.equal(check.mock.callCount(), 0);
  assert.equal(clear.mock.callCount(), 1);
  assert.equal(updateUser.mock.callCount(), 0);
});
