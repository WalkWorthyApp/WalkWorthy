import { test } from "node:test";
import assert from "node:assert/strict";
import { moderateText } from "../lib/content-safety";
import {
  runMoodAgent, CRISIS_RESPONSE, BLOCKED_OUTPUT_RESPONSE,
  UNAVAILABLE_INPUT_RESPONSE, type MoodAgentInput,
} from "../lib/mood-agent";
import { runReflectionAgent, FIXED_REFLECTION } from "../lib/reflection-agent";
import { safeErrorMetadata } from "../shared/safe-logging";

const input: MoodAgentInput = {
  profile: null,
  checkInType: "morning",
  moodSpectrumData: {
    moodScore: 5, moodLevel: "neutral", emotionTags: ["Calm"],
    impactCategories: [], followUpScore: 3, note: "A synthetic test note",
  },
};

function decision(crisis = false): Response {
  return new Response(JSON.stringify({ results: [{
    flagged: crisis, categories: {
      "self-harm": false, "self-harm/intent": crisis, "self-harm/instructions": false,
    },
  }] }), { status: 200 });
}

test("moderation transport failures remain unavailable, never approved", async (t) => {
  const cases: Array<() => Promise<Response>> = [
    async () => { throw new TypeError("synthetic private note"); },
    async () => { throw new DOMException("synthetic private note", "AbortError"); },
    async () => new Response("private upstream response", { status: 503 }),
    async () => new Response("not json", { status: 200 }),
    async () => new Response(JSON.stringify({ results: [] }), { status: 200 }),
  ];
  for (const fetchResponse of cases) {
    const mocked = t.mock.method(globalThis, "fetch", fetchResponse);
    assert.equal(await moderateText("synthetic private note", "test-key"), "unavailable");
    mocked.mock.restore();
  }
});

test("unavailable input screening preserves fixed encouragement and skips generation", async (t) => {
  t.mock.method(globalThis, "fetch", async () => new Response("", { status: 503 }));
  let generations = 0;
  const result = await runMoodAgent(input, "test-key", async () => {}, undefined, async () => {
    generations++;
    throw new Error("Generation must not run");
  });
  assert.equal(generations, 0);
  assert.deepEqual(result, UNAVAILABLE_INPUT_RESPONSE);
  assert.equal(result.isGenerated, false);
  assert.equal(result.supportResource, undefined);
  assert.doesNotMatch(result.message, /suicid|self.harm|988/i);
});

test("actual self-harm classification retains crisis card and skips generation", async (t) => {
  t.mock.method(globalThis, "fetch", async () => decision(true));
  let generations = 0;
  const result = await runMoodAgent(input, "test-key", async () => {}, undefined, async () => {
    generations++;
    throw new Error("Generation must not run");
  });
  assert.equal(generations, 0);
  assert.deepEqual(result, CRISIS_RESPONSE);
  assert.equal(result.supportResource?.phone, "988");
  assert.equal(result.isGenerated, false);
});

test("unavailable or flagged output cannot leak generated prose or imply user crisis", async (t) => {
  for (const outputResponse of [
    () => new Response("", { status: 503 }),
    () => decision(true),
  ]) {
    let calls = 0;
    const mocked = t.mock.method(globalThis, "fetch", async () => ++calls === 1 ? decision() : outputResponse());
    const result = await runMoodAgent(input, "test-key", async () => {}, undefined, async () => ({
      message: "UNSCREENED_GENERATION_SENTINEL", verseId: "psalm_46_1",
    }));
    assert.equal(calls, 2);
    assert.deepEqual(result, BLOCKED_OUTPUT_RESPONSE);
    assert.equal(result.supportResource, undefined);
    assert.doesNotMatch(JSON.stringify(result), /UNSCREENED_GENERATION_SENTINEL/);
    mocked.mock.restore();
  }
});

test("approved generation is explicitly labelled as generated", async (t) => {
  t.mock.method(globalThis, "fetch", async () => decision());
  const result = await runMoodAgent(input, "test-key", async () => {}, undefined, async () => ({
    message: "Take a quiet moment today.", verseId: "psalm_46_1",
  }));
  assert.equal(result.isGenerated, true);
  assert.equal(result.message, "Take a quiet moment today.");
});

test("reflection output outage returns fixed content with truthful provenance", async (t) => {
  t.mock.method(globalThis, "fetch", async () => { throw new TypeError("synthetic provider failure"); });
  const result = await runReflectionAgent([], "test-key", async () => {}, null, async () => ({
    reflection: "UNSCREENED_REFLECTION_SENTINEL",
  }));
  assert.deepEqual(result, FIXED_REFLECTION);
  assert.equal(result.isGenerated, false);
  assert.doesNotMatch(result.reflection, /UNSCREENED_REFLECTION_SENTINEL/);
});

test("approved reflection retains generated provenance", async (t) => {
  t.mock.method(globalThis, "fetch", async () => decision());
  const result = await runReflectionAgent([], "test-key", async () => {}, null, async () => ({ reflection: "A quiet reflection." }));
  assert.deepEqual(result, { reflection: "A quiet reflection.", isGenerated: true });
});

test("safe diagnostics never expose arbitrary names, messages, or attached payloads", () => {
  const error = new Error("private note sentinel");
  error.name = "private name sentinel";
  Object.assign(error, { cause: "private cause sentinel", response: { data: "private response sentinel" } });
  assert.deepEqual(safeErrorMetadata(error), { errorKind: "Error" });
  assert.deepEqual(safeErrorMetadata({ name: "TypeError", message: "private" }), { errorKind: "UnknownError" });
  assert.deepEqual(safeErrorMetadata(new TypeError("private")), { errorKind: "TypeError" });
});
