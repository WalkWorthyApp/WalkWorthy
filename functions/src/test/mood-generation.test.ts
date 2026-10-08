import assert from 'node:assert/strict';
import test from 'node:test';
import { initializeApp, deleteApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { randomUUID } from 'node:crypto';
import { moodGenerationRef, type MoodGenerationIdentity } from '../shared/mood-generation';
import { runMoodAgent, CRISIS_RESPONSE, type MoodAgentInput } from '../lib/mood-agent';
import { validateMoodSpectrumData } from '../shared/types';

const input: MoodAgentInput = { checkInType: 'morning', moodSpectrumData: {
  moodScore: 5, moodLevel: 'neutral', followUpScore: 2, note: null,
  emotionTags: ['Calm', 'Hopeful'], impactCategories: ['Work', 'Family'],
} };

test('claim identity covers normalized context, intent, user, date and generation version', async () => {
  const app = initializeApp({ projectId: 'demo-walkworthy-compliance' }, randomUUID());
  const db = getFirestore(app);
  const identity: MoodGenerationIdentity = { checkInDocId: 'day_morning', input: input.moodSpectrumData,
    regenerate: false, baseVersion: 'one', profileContext: null };
  const key = (value = identity, uid = 'user') => moodGenerationRef(db, uid, value).path;
  try {
    const normalized = validateMoodSpectrumData({ moodScore: 5, followUpScore: 2,
      emotionTags: ['Hopeful', 'Calm', 'invalid'], impactCategories: ['Family', 'Work'] });
    assert.ok(normalized);
    assert.equal(key({ ...identity, input: normalized }), key());
    for (const change of [{ moodScore: 6 }, { followUpScore: 3 }, { note: '' }, { note: 'PRIVATE_SENTINEL' },
      { emotionTags: ['Calm', 'Calm'] }, { impactCategories: ['Family'] }]) {
      assert.notEqual(key({ ...identity, input: { ...identity.input, ...change } }), key());
    }
    for (const change of [{ checkInDocId: 'day_midday' }, { checkInDocId: 'tomorrow_morning' },
      { regenerate: true }, { baseVersion: 'two' }, { profileContext: { occupation: 'PRIVATE_SENTINEL' } }]) {
      const path = key({ ...identity, ...change });
      assert.notEqual(path, key());
      assert.doesNotMatch(path, /PRIVATE_SENTINEL/);
    }
    assert.notEqual(key(identity, 'another-user'), key());
  } finally { await deleteApp(app); }
});

test('generation admission runs before each dispatch, and admission errors never retry', async () => {
  const events: string[] = [];
  await assert.rejects(runMoodAgent(input, 'synthetic-key', async () => {}, undefined, async () => {
    events.push('dispatch');
    throw new Error('Synthetic provider failure');
  }, async () => { events.push('admit'); }));
  assert.deepEqual(events, ['admit', 'dispatch', 'admit', 'dispatch']);
  events.length = 0;
  const denied = new Error('Ownership lost');
  await assert.rejects(runMoodAgent(input, 'synthetic-key', async () => {}, undefined, async () => {
    events.push('dispatch');
  }, async () => { events.push('admit'); throw denied; }), error => error === denied);
  assert.deepEqual(events, ['admit']);
});

test('fixed input response never starts paid generation or consumes its reservation', async t => {
  t.mock.method(globalThis, 'fetch', async () => new Response(JSON.stringify({ results: [{ flagged: true,
    categories: { 'self-harm': false, 'self-harm/intent': true, 'self-harm/instructions': false },
  }] }), { status: 200 }));
  const actual = await runMoodAgent({ ...input, moodSpectrumData: { ...input.moodSpectrumData, note: 'Synthetic note' } },
    'synthetic-key', async () => {}, undefined, async () => { throw new Error('Unexpected dispatch'); },
    async () => { throw new Error('Unexpected reservation consumption'); });
  assert.deepEqual(actual, CRISIS_RESPONSE);
});
