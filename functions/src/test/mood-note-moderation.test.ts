import { test, type TestContext } from "node:test";
import assert from "node:assert/strict";
import {
  runMoodAgent, CRISIS_RESPONSE, BLOCKED_INPUT_RESPONSE,
  UNAVAILABLE_INPUT_RESPONSE, type MoodAgentInput,
} from "../lib/mood-agent";
import { validateMoodSpectrumData } from "../shared/types";
import { AiConsentRequiredError } from "../shared/privacy-consent";

const generated = { message: "Take a quiet moment today.", verseId: "psalm_46_1" };

function inputWithNote(note?: string): MoodAgentInput {
  const moodSpectrumData = validateMoodSpectrumData({
    moodScore: 5, emotionTags: ["Calm"], impactCategories: [], followUpScore: 3, note,
  });
  assert.ok(moodSpectrumData, "the note must be accepted by the API validator");
  return { profile: null, checkInType: "morning", moodSpectrumData };
}

function decision(category?: "self-harm/intent" | "violence"): Response {
  return new Response(JSON.stringify({ results: [{
    flagged: category !== undefined,
    categories: {
      "self-harm": false, "self-harm/intent": false, "self-harm/instructions": false,
      ...(category ? { [category]: true } : {}),
    },
  }] }), { status: 200 });
}

function mockModeration(
  t: TestContext,
  classify: (text: string) => Response = () => decision(),
): string[] {
  const screened: string[] = [];
  t.mock.method(globalThis, "fetch", async (_url: unknown, init?: RequestInit) => {
    assert.ok(init && typeof init.body === "string");
    const body = JSON.parse(init.body) as { input: string };
    screened.push(body.input);
    return classify(body.input);
  });
  return screened;
}

for (const failAt of [1, 2]) {
  test(`full-note screening preserves consent boundary ${failAt}`, async (t) => {
    const note = "Today was calm. ".repeat(31) + "Okay";
    const screened = mockModeration(t);
    const denied = new AiConsentRequiredError();
    let checks = 0;
    let generations = 0;
    await assert.rejects(runMoodAgent(inputWithNote(note), "test-key", async () => {
      if (++checks === failAt) throw denied;
    }, undefined, async () => {
      generations++;
      return generated;
    }), error => error === denied);
    assert.equal(checks, failAt);
    assert.equal(generations, 0);
    assert.deepEqual(screened, failAt === 1 ? [] : [note]);
  });
}

for (const { suffix, category, expected } of [
  { suffix: "CRISIS_SENTINEL", category: "self-harm/intent", expected: CRISIS_RESPONSE },
  { suffix: "BLOCK_SENTINEL", category: "violence", expected: BLOCKED_INPUT_RESPONSE },
] as const) {
  test(`a ${category} signal after character 400 skips generation`, async (t) => {
    const note = "Today was calm. ".repeat(30) + suffix;
    assert.ok(note.indexOf(suffix) > 400);
    const input = inputWithNote(note);
    const screened = mockModeration(t, text => text.includes(suffix) ? decision(category) : decision());
    let generations = 0;
    const result = await runMoodAgent(input, "test-key", async () => {}, undefined, async () => {
      generations++;
      return generated;
    });
    assert.deepEqual(result, expected);
    assert.equal(generations, 0);
    assert.deepEqual(screened, [note]);
    assert.equal(input.moodSpectrumData.note, note);
  });
}

test("all 500 accepted characters are screened while generation retains its 300-character limit", async (t) => {
  const note = "Today was calm. ".repeat(31) + "Okay";
  assert.equal(note.length, 500);
  const input = inputWithNote(note);
  const screened = mockModeration(t);
  let generationNote: string | undefined;
  let generations = 0;
  const result = await runMoodAgent(input, "test-key", async () => {}, undefined, async serialized => {
    generations++;
    generationNote = (JSON.parse(serialized) as { note?: string }).note;
    return generated;
  });
  assert.deepEqual(screened, [note, generated.message]);
  assert.equal(generations, 1);
  assert.equal(generationNote, note.slice(0, 300));
  assert.equal(result.isGenerated, true);
  assert.equal(result.message, generated.message);
  assert.equal(input.moodSpectrumData.note, note);
});

test("normalization preserves a late signal for input screening", async (t) => {
  const suffix = "CRISIS_SENTINEL";
  const prefix = "Today was calm. ".repeat(26);
  const note = `<b>Fine</b>\thttps://example.test\n${prefix}\u2003${suffix}`;
  const normalized = `Fine ${prefix}${suffix}`;
  const input = inputWithNote(note);
  const screened = mockModeration(t, text => text.includes(suffix) ? decision("self-harm/intent") : decision());
  let generations = 0;
  const result = await runMoodAgent(input, "test-key", async () => {}, undefined, async () => {
    generations++;
    return generated;
  });
  assert.deepEqual(result, CRISIS_RESPONSE);
  assert.equal(generations, 0);
  assert.deepEqual(screened, [normalized]);
  assert.equal(input.moodSpectrumData.note, note);
});

test("failed screening of a long note skips generation without a crisis card", async (t) => {
  const note = "Today was calm. ".repeat(31) + "Okay";
  const screened = mockModeration(t, () => new Response("", { status: 503 }));
  let generations = 0;
  const result = await runMoodAgent(inputWithNote(note), "test-key", async () => {}, undefined, async () => {
    generations++;
    return generated;
  });
  assert.deepEqual(screened, [note]);
  assert.deepEqual(result, UNAVAILABLE_INPUT_RESPONSE);
  assert.equal(result.supportResource, undefined);
  assert.equal(generations, 0);
});

for (const { label, note, normalized } of [
  { label: "omitted", note: undefined, normalized: undefined },
  { label: "empty", note: "", normalized: undefined },
  { label: "whitespace-only", note: " \t\n\u2003 ", normalized: "" },
  { label: "stripped-only", note: "<br>https://example.test", normalized: "" },
  { label: "short", note: "<b>Calm</b>\n today. ", normalized: "Calm today." },
]) {
  test(`${label} notes retain generation and screening behavior`, async (t) => {
    const screened = mockModeration(t);
    let generationNote: string | undefined;
    let generations = 0;
    const result = await runMoodAgent(inputWithNote(note), "test-key", async () => {}, undefined, async serialized => {
      generations++;
      generationNote = (JSON.parse(serialized) as { note?: string }).note;
      return generated;
    });
    assert.deepEqual(screened, normalized ? [normalized, generated.message] : [generated.message]);
    assert.equal(generationNote, normalized);
    assert.equal(generations, 1);
    assert.equal(result.message, generated.message);
    assert.equal(result.isGenerated, true);
  });
}
