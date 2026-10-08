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
import limits = require('../shared/rate-limiter');
import { moodCheckIn } from '../api/mood-checkin';
import { shiftLogicalDate } from '../shared/time';

const userId = 'synthetic-log-user';
function entry(date: string, checkInType = 'morning', owner = userId) {
  return { id: `${date}_${checkInType}`, date, checkInType, userId: owner,
    aiResponse: { message: 'Take a quiet moment today.' } };
}
type Entry = ReturnType<typeof entry>;
type Filter = { field: keyof Entry; op: '>=' | '<=' | '<'; value: string };
interface Read { path: string; filters: Filter[]; limit: number }
interface LogResponse {
  checkIns: Entry[];
  daysRequested: number;
  windowStartDate: string;
  windowEndDate: string;
  hasMoreCheckIns: boolean;
}

// Immutable queries model Firestore's filtering/sorting/limit behavior, rather
// than always handing the handler a preselected result regardless of its bounds.
function memoryStore(rows: Entry[]) {
  const reads: Read[] = [];
  function query(path: string, filters: Filter[] = [], limit = Infinity, descending = false) {
    return {
      doc: (id: string) => ({ collection: (name: string) => query(`${path}/${id}/${name}`) }),
      where: (field: keyof Entry, op: Filter['op'], value: string) => query(path, [...filters, { field, op, value }], limit, descending),
      orderBy: (field: string, direction: string) => {
        assert.equal(field, 'date');
        return query(path, filters, limit, direction === 'desc');
      },
      limit: (count: number) => query(path, filters, count, descending),
      get: async () => {
        reads.push({ path, filters, limit });
        const docs = rows.filter(row => path === `users/${row.userId}/moodCheckIns`
          && filters.every(({ field, op, value }) => {
            const actual = row[field];
            assert.equal(typeof actual, 'string');
            return op === '>=' ? actual >= value : op === '<=' ? actual <= value : actual < value;
          }))
          .sort((a, b) => descending ? b.date.localeCompare(a.date) : a.date.localeCompare(b.date))
          .slice(0, limit).map(row => ({ data: () => row }));
        return { docs };
      },
    };
  }
  return { db: { collection: (name: string) => query(name) }, reads };
}

function prepare(t: TestContext, options: {
  rows?: Entry[]; now?: string; timezone?: string; owner?: string;
  db?: FirebaseFirestore.Firestore;
} = {}) {
  t.mock.timers.enable({ apis: ['Date'], now: new Date(options.now ?? '2026-10-08T12:00:00Z') });
  const memory = memoryStore(options.rows ?? []);
  t.mock.method(firebase, 'getDb', () => options.db ?? memory.db);
  t.mock.method(auth, 'verifyAppCheck', async () => true);
  t.mock.method(auth, 'requireAuth', async (req: Request) => Object.assign(req, { userId: options.owner ?? userId }));
  t.mock.method(profiles, 'getUserProfileOnce', async () => ({ timezone: options.timezone ?? 'UTC' }));
  t.mock.method(limits, 'checkRateLimit', async () => ({ allowed: true, retryAfterSeconds: 0 }));
  return memory;
}

async function request(query: Record<string, string> = {}) {
  let status = 200;
  let body: unknown;
  const res = {
    setHeader: () => res,
    status: (code: number) => { status = code; return res; },
    json: (payload: unknown) => { body = payload; return res; },
  };
  await moodCheckIn({ method: 'GET', query: { fullHistory: '14', ...query } } as unknown as Request, res as unknown as Response);
  return { status, body: body as LogResponse };
}

async function page(query: Record<string, string> = {}) {
  const result = await request(query);
  assert.equal(result.status, 200, JSON.stringify(result.body));
  return result.body;
}

function denseRows() {
  return Array.from({ length: 29 }, (_, day) => ['morning', 'midday', 'evening']
    .map(type => entry(shiftLogicalDate('2026-10-08', -day), type))).flat();
}

test('full history: iOS older-page parameters retrieve earlier records with no explicit startDate', async t => {
  const { reads } = prepare(t, { rows: [entry('2026-10-07'), entry('2026-09-20'), entry('2026-08-30'), entry('2026-08-29', 'morning', 'someone-else')] });
  const first = await page();
  assert.deepEqual([first.windowStartDate, first.windowEndDate], ['2026-09-24', '2026-10-08']);
  assert.deepEqual(first.checkIns.map(c => c.date), ['2026-10-07']);
  const older = await page({ endDate: '2026-09-23' });
  assert.deepEqual([older.windowStartDate, older.windowEndDate], ['2026-09-10', '2026-09-23']);
  assert.deepEqual(older.checkIns.map(c => c.date), ['2026-09-20']);
  assert.equal(older.hasMoreCheckIns, true);
  const last = await page({ endDate: '2026-09-09' });
  assert.deepEqual(last.checkIns.map(c => c.date), ['2026-08-30']);
  assert.equal(last.hasMoreCheckIns, false);
  assert.deepEqual(reads.map(r => r.limit), [45, 1, 42, 1, 42, 1]);
  assert.ok(reads.every(r => r.path === `users/${userId}/moodCheckIns`));
  assert.deepEqual(reads[3].filters, [{ field: 'date', op: '<', value: '2026-09-10' }]);
});

test('full history: dense adjacent windows return every boundary-day check-in exactly once', async t => {
  const rows = denseRows();
  prepare(t, { rows });
  const first = await page();
  const older = await page({ endDate: shiftLogicalDate(first.windowStartDate, -1) });
  assert.equal(first.checkIns.length, 45);
  assert.equal(older.checkIns.length, 42);
  assert.equal(older.hasMoreCheckIns, false);
  const returned = [...first.checkIns, ...older.checkIns].map(c => c.id);
  assert.equal(new Set(returned).size, rows.length);
  assert.deepEqual(returned.sort(), rows.map(c => c.id).sort());
});

test('full history: empty recent and middle windows do not hide records beyond a gap', async t => {
  prepare(t, { rows: [entry('2026-08-30')] });
  const queries: Record<string, string>[] = [{}, { endDate: '2026-09-23' }];
  for (const query of queries) {
    const result = await page(query);
    assert.deepEqual(result.checkIns, []);
    assert.equal(result.hasMoreCheckIns, true);
  }
  assert.equal((await page({ endDate: '2026-09-09' })).checkIns.length, 1);
  const exhausted = await page({ endDate: '2026-08-26' });
  assert.deepEqual(exhausted.checkIns, []);
  assert.equal(exhausted.hasMoreCheckIns, false);
});

test('full history: screened-out entries do not imply exhaustion or bypass the screen', async t => {
  const hidden = entry('2026-09-20');
  hidden.aiResponse.message = 'Contact synthetic.person@example.com';
  prepare(t, { rows: [hidden, entry('2026-08-30')] });
  const result = await page({ endDate: '2026-09-23' });
  assert.deepEqual(result.checkIns, []);
  assert.equal(result.hasMoreCheckIns, true);
});

for (const [endDate, expectedStart] of [
  ['2027-01-05', '2026-12-23'],
  ['2024-03-05', '2024-02-21'],
  ['2026-03-10', '2026-02-25'], // spring DST
  ['2026-11-05', '2026-10-23'], // fall DST
]) {
  test(`full history: calendar window ending ${endDate}`, async t => {
    prepare(t, { timezone: 'America/New_York' });
    const result = await page({ endDate });
    assert.deepEqual([result.windowStartDate, result.windowEndDate], [expectedStart, endDate]);
  });
}

test('full history: initial boundaries use the profile timezone and calendar days across DST', async t => {
  prepare(t, { timezone: 'America/New_York', now: '2026-03-09T04:30:00Z' });
  const first = await page();
  // 00:30 in New York, when subtracting 14 * 24 hours lands a calendar day early.
  assert.deepEqual([first.windowStartDate, first.windowEndDate], ['2026-02-23', '2026-03-09']);
});

test('full history: server cursor works when profile date differs from device/UTC date', async t => {
  prepare(t, { timezone: 'America/Los_Angeles', now: '2026-10-08T01:00:00Z' });
  const first = await page();
  assert.deepEqual([first.windowStartDate, first.windowEndDate], ['2026-09-23', '2026-10-07']);
  const older = await page({ endDate: shiftLogicalDate(first.windowStartDate, -1) });
  assert.deepEqual([older.windowStartDate, older.windowEndDate], ['2026-09-09', '2026-09-22']);
});

test('full history: explicit valid ranges are complete and maximum queries stay bounded', async t => {
  const { reads } = prepare(t, { rows: denseRows() });
  const explicit = await page({ startDate: '2026-09-20', endDate: '2026-09-23' });
  assert.equal(explicit.checkIns.length, 12);
  assert.equal(reads[0].limit, 12);
  const maximum = await page({ fullHistory: '999' });
  assert.equal(maximum.daysRequested, 31);
  assert.equal(reads[2].limit, 96);
});

const invalidRanges: Record<string, string>[] = [
  { endDate: '2026-02-30' }, { endDate: '2026-13-01' },
  { startDate: '2026-10-09' }, // after the implicit end (today)
  { startDate: '2026-09-24', endDate: '2026-09-23' },
  { startDate: '2026-01-01', endDate: '2026-10-08' },
  { endDate: '0000-01-01' }, // computed start falls outside YYYY-MM-DD
];
for (const query of invalidRanges) {
  test(`full history: rejects invalid resolved range ${JSON.stringify(query)}`, async t => {
    const { reads } = prepare(t);
    assert.equal((await request(query)).status, 400);
    assert.deepEqual(reads, []);
  });
}

test('full history emulator: real queries cover dense boundaries, gaps, screening and owner isolation', {
  skip: !process.env.FIRESTORE_EMULATOR_HOST,
}, async t => {
  const app = initializeApp({ projectId: 'demo-walkworthy-compliance' }, randomUUID());
  const db = getFirestore(app);
  const owner = `log-${randomUUID()}`;
  const other = `log-${randomUUID()}`;
  t.after(async () => {
    await Promise.all([owner, other].map(uid => db.recursiveDelete(db.doc(`users/${uid}`))));
    await deleteApp(app);
  });
  prepare(t, { db, owner });
  const collection = db.collection(`users/${owner}/moodCheckIns`);
  const batch = db.batch();
  for (const row of denseRows()) batch.set(collection.doc(row.id), { ...row, userId: owner });
  batch.set(collection.doc('2026-08-01_morning'), entry('2026-08-01', 'morning', owner));
  batch.set(db.doc(`users/${other}/moodCheckIns/2026-07-01_morning`), entry('2026-07-01', 'morning', other));
  await batch.commit();
  const first = await page();
  const older = await page({ endDate: '2026-09-23' });
  assert.equal(first.checkIns.length, 45);
  assert.equal(older.checkIns.length, 42);
  assert.equal(new Set([...first.checkIns, ...older.checkIns].map(c => c.id)).size, 87);
  const gap = await page({ endDate: '2026-09-09' });
  assert.deepEqual(gap.checkIns, []);
  assert.equal(gap.hasMoreCheckIns, true);
  const hidden = entry('2026-08-20', 'morning', owner);
  hidden.aiResponse.message = 'Contact synthetic.person@example.com';
  await collection.doc(hidden.id).set(hidden);
  const screened = await page({ endDate: '2026-08-26' });
  assert.deepEqual(screened.checkIns, []);
  assert.equal(screened.hasMoreCheckIns, true);
  const last = await page({ endDate: '2026-08-12' });
  assert.deepEqual(last.checkIns.map(c => c.date), ['2026-08-01']);
  assert.equal(last.hasMoreCheckIns, false);
  assert.equal((await page({ endDate: '2026-07-29' })).hasMoreCheckIns, false);
});
