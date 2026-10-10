import { test } from "node:test";
import assert from "node:assert/strict";
import { Usage } from "@openai/agents";
import { RequestMetrics } from "../shared/request-metrics";
import { runMoodAgent, type MoodAgentInput } from "../lib/mood-agent";
import { validateMoodSpectrumData } from "../shared/types";

test("time() accumulates repeated stages and still records a stage that throws", async (t) => {
  let clock = 1000;
  t.mock.method(performance, "now", () => clock);
  const metrics = new RequestMetrics();

  await metrics.time("consent", async () => { clock += 10; });
  await metrics.time("consent", async () => { clock += 5.4; });
  const failure = new Error("Synthetic failure");
  await assert.rejects(metrics.time("model", async () => {
    clock += 20;
    throw failure;
  }), (error) => error === failure);
  metrics.add("modelAttempts");

  assert.deepEqual(metrics.summary(), { consentMs: 15, modelMs: 20, modelAttempts: 1, totalMs: 35 });
});

test("token usage reads cached tokens from the SDK's Usage shape", () => {
  const metrics = new RequestMetrics();
  // Built the way @openai/agents-openai builds Usage from a Responses API reply.
  metrics.recordTokenUsage(new Usage({
    inputTokens: 3000, outputTokens: 80, totalTokens: 3080,
    inputTokensDetails: { cached_tokens: 2048 }, outputTokensDetails: {},
  }));
  metrics.recordTokenUsage(new Usage({
    inputTokens: 3000, outputTokens: 70, totalTokens: 3070,
    inputTokensDetails: {}, outputTokensDetails: {},
  }));

  const { totalMs, ...tokens } = metrics.summary();
  assert.equal(typeof totalMs, "number");
  assert.deepEqual(tokens, { inputTokens: 6000, cachedInputTokens: 2048, outputTokens: 150 });
});

test("runMoodAgent records each stage of a generated response", async (t) => {
  t.mock.method(globalThis, "fetch", async () => new Response(JSON.stringify({ results: [{
    flagged: false,
    categories: { "self-harm": false, "self-harm/intent": false, "self-harm/instructions": false },
  }] }), { status: 200 }));
  const moodSpectrumData = validateMoodSpectrumData({
    moodScore: 5, emotionTags: ["Calm"], impactCategories: [], followUpScore: 3, note: "Synthetic note",
  });
  assert.ok(moodSpectrumData);
  const metrics = new RequestMetrics();
  const input: MoodAgentInput = { checkInType: "morning", moodSpectrumData, metrics };

  await runMoodAgent(input, "synthetic-key", async () => {}, undefined,
    async () => ({ message: "Take a quiet moment today.", verseId: "psalm_46_1" }));

  const summary = metrics.summary();
  assert.deepEqual(Object.keys(summary).sort(), [
    "agentConsentMs", "generationClaimMs", "inputModerationMs", "modelAttempts", "modelMs",
    "outputModerationMs", "resultCheckMs", "totalMs",
  ]);
  assert.equal(summary.modelAttempts, 1);
  for (const value of Object.values(summary)) assert.equal(typeof value, "number");
});
