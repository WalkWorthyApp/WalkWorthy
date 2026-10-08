import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { runMoodAgent, type MoodAgentInput } from '../lib/mood-agent';
import { runReflectionAgent } from '../lib/reflection-agent';
import { type ProviderConsentCheck } from '../lib/provider-model';
import { AiConsentRequiredError } from '../shared/privacy-consent';
import { AccountDeletingError } from '../shared/account-lifecycle';
import config = require('../lib/model-config');

const input: MoodAgentInput = {
  profile: null, checkInType: 'morning',
  moodSpectrumData: {
    moodScore: 5, moodLevel: 'neutral', emotionTags: ['Calm'],
    impactCategories: [], followUpScore: 3, note: 'A synthetic test note',
  },
};
const moodOutput = { message: 'Take a quiet moment today.', verseId: 'psalm_46_1' };
const reflectionOutput = { reflection: 'Take a quiet moment today.' };
const agents = [
  {
    name: 'mood', inputModerations: 1, output: moodOutput,
    invoke: (check: ProviderConsentCheck, generate?: config.GenerationRunner) =>
      runMoodAgent(input, `synthetic-${randomUUID()}`, check, undefined, generate),
  },
  {
    name: 'reflection', inputModerations: 0, output: reflectionOutput,
    invoke: (check: ProviderConsentCheck, generate?: config.GenerationRunner) =>
      runReflectionAgent([], `synthetic-${randomUUID()}`, check, null, generate),
  },
];

function allowed(): Response {
  return Response.json({ results: [{ flagged: false, categories: {
    'self-harm': false, 'self-harm/intent': false, 'self-harm/instructions': false,
  } }] });
}

test('mood withdrawal after input moderation prevents generation', async t => {
  let active = true;
  const denied = new AiConsentRequiredError();
  const moderation = t.mock.method(globalThis, 'fetch', async () => {
    active = false;
    return allowed();
  });
  let generations = 0;
  await assert.rejects(agents[0].invoke(async () => {
    if (!active) throw denied;
  }, async () => { generations++; return moodOutput; }), error => error === denied);
  assert.equal(moderation.mock.callCount(), 1);
  assert.equal(generations, 0);
});

for (const agent of agents) {
  test(`${agent.name}: profile echo rejection still stops without retry`, async t => {
    t.mock.method(globalThis, 'fetch', async () => allowed());
    const delay = t.mock.method(config, 'sleep', async () => {});
    let generations = 0;
    const generate = async () => {
      generations++;
      return agent.name === 'mood'
        ? { message: 'Your marine biology studies matter.', verseId: 'psalm_46_1' }
        : { reflection: 'Your marine biology studies matter.' };
    };
    const profile = { major: 'Marine Biology' };
    const result = agent.name === 'mood'
      ? runMoodAgent({ ...input, profile }, 'synthetic', async () => {}, undefined, generate)
      : runReflectionAgent([], 'synthetic', async () => {}, profile, generate);
    await assert.rejects(result, config.GuardrailTripError);
    assert.equal(generations, 1);
    assert.equal(delay.mock.callCount(), 0);
  });

  test(`${agent.name}: withdrawal after generation prevents output moderation`, async t => {
    let active = true;
    const denied = new AiConsentRequiredError();
    const moderation = t.mock.method(globalThis, 'fetch', async () => allowed());
    let generations = 0;
    await assert.rejects(agent.invoke(async () => {
      if (!active) throw denied;
    }, async () => { generations++; active = false; return agent.output; }), error => error === denied);
    assert.equal(generations, 1);
    assert.equal(moderation.mock.callCount(), agent.inputModerations);
  });

  test(`${agent.name}: withdrawal during backoff prevents the next generation`, async t => {
    let active = true;
    const denied = new AiConsentRequiredError();
    const moderation = t.mock.method(globalThis, 'fetch', async () => allowed());
    const delay = t.mock.method(config, 'sleep', async () => { active = false; });
    let generations = 0;
    await assert.rejects(agent.invoke(async () => {
      if (!active) throw denied;
    }, async () => { generations++; throw new Error('Synthetic provider failure'); }), error => error === denied);
    assert.equal(generations, 1);
    assert.equal(delay.mock.callCount(), 1);
    assert.equal(moderation.mock.callCount(), agent.inputModerations);
  });

  test(`${agent.name}: all consent-check failures propagate without retry or fallback`, async t => {
    for (const error of [new AiConsentRequiredError(), new AccountDeletingError(), new TypeError('Synthetic read failure')]) {
      // Exercise first dispatch, after input moderation (mood), and after generation.
      for (let failAt = 1; failAt <= agent.inputModerations + 2; failAt++) {
        await t.test(`${error.constructor.name} at boundary ${failAt}`, async child => {
          let checks = 0;
          let generations = 0;
          const moderation = child.mock.method(globalThis, 'fetch', async () => allowed());
          const delay = child.mock.method(config, 'sleep', async () => {});
          await assert.rejects(agent.invoke(async () => {
            if (++checks === failAt) throw error;
          }, async () => { generations++; return agent.output; }), caught => caught === error);
          assert.equal(generations, failAt === agent.inputModerations + 2 ? 1 : 0);
          assert.equal(moderation.mock.callCount(), failAt > 1 ? agent.inputModerations : 0);
          assert.equal(delay.mock.callCount(), 0);
        });
      }
    }
  });

  test(`${agent.name}: unchanged consent permits a guarded provider retry and output screening`, async t => {
    const moderation = t.mock.method(globalThis, 'fetch', async () => allowed());
    const delay = t.mock.method(config, 'sleep', async () => {});
    let generations = 0;
    let checks = 0;
    const result = await agent.invoke(async () => { checks++; }, async () => {
      if (++generations === 1) throw new Error('Synthetic transient failure');
      return agent.output;
    });
    assert.equal(result.isGenerated, true);
    assert.equal(generations, 2);
    assert.equal(checks, agent.inputModerations + 3);
    assert.equal(moderation.mock.callCount(), agent.inputModerations + 1);
    assert.equal(delay.mock.callCount(), 1);
  });

  test(`${agent.name}: real SDK cannot retry HTTP failures or empty-output turns after withdrawal`, async t => {
    for (const outcome of ['429', '500', 'connection', 'empty-output'] as const) {
      await t.test(outcome, async child => {
        let active = true;
        let generations = 0;
        let moderations = 0;
        const denied = new AiConsentRequiredError();
        child.mock.method(config, 'sleep', async () => {});
        child.mock.method(globalThis, 'fetch', async (url: string | URL | Request, options?: RequestInit) => {
          if (String(url).endsWith('/moderations')) { moderations++; return allowed(); }
          assert.ok(String(url).endsWith('/responses'));
          assert.equal(JSON.parse(String(options?.body)).store, false);
          assert.ok(options?.signal instanceof AbortSignal);
          assert.equal(new Headers(options?.headers).get('x-stainless-retry-count'), '0');
          generations++;
          active = false;
          if (outcome === 'connection') throw new TypeError('Synthetic connection failure');
          if (outcome === 'empty-output') return Response.json({ id: 'synthetic', output: [] });
          return Response.json({ error: { message: 'Synthetic retryable failure' } }, { status: Number(outcome) });
        });
        await assert.rejects(agent.invoke(async () => {
          if (!active) throw denied;
        }), error => error === denied);
        assert.equal(generations, 1);
        assert.equal(moderations, agent.inputModerations);
      });
    }
  });

  test(`${agent.name}: real SDK still produces screened output with unchanged consent`, async t => {
    let generations = 0;
    let moderations = 0;
    t.mock.method(globalThis, 'fetch', async (url: string | URL | Request) => {
      if (String(url).endsWith('/moderations')) { moderations++; return allowed(); }
      assert.ok(String(url).endsWith('/responses'));
      generations++;
      return Response.json({ id: 'synthetic', output: [{
        id: 'synthetic-message', type: 'message', role: 'assistant', status: 'completed',
        content: [{ type: 'output_text', text: JSON.stringify(agent.output), annotations: [] }],
      }] });
    });
    const result = await agent.invoke(async () => {});
    assert.equal(result.isGenerated, true);
    assert.equal(generations, 1);
    assert.equal(moderations, agent.inputModerations + 1);
  });
}
