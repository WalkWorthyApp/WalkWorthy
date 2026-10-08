import { test } from "node:test";
import assert from "node:assert/strict";
import { classifyModerationResult } from "../lib/content-safety";

function response(flagged: boolean, categories: Record<string, unknown>) {
  return { results: [{ flagged, categories: {
    "self-harm": false, "self-harm/intent": false, "self-harm/instructions": false,
    ...categories,
  } }] };
}

test("moderation parser allows unflagged content", () => {
  assert.equal(classifyModerationResult(response(false, {})), "allow");
});

test("moderation parser accepts documented nullable illicit categories", () => {
  for (const categories of [
    { illicit: null, "illicit/violent": false },
    { illicit: false, "illicit/violent": null },
    { illicit: null, "illicit/violent": null },
  ]) {
    assert.equal(classifyModerationResult(response(false, categories)), "allow");
  }
});

test("nullable illicit categories preserve crisis and blocked decisions", () => {
  const nullable = { illicit: null, "illicit/violent": null };
  assert.equal(classifyModerationResult(response(true, {
    ...nullable, "self-harm/intent": true,
  })), "crisis");
  assert.equal(classifyModerationResult(response(true, {
    ...nullable, violence: true,
  })), "block");
  assert.equal(classifyModerationResult(response(true, { illicit: true })), "block");
});

test("nullable support does not approve unexpected nulls or contradictory flags", () => {
  for (const name of ["self-harm", "self-harm/intent", "self-harm/instructions", "violence", "unknown"]) {
    assert.throws(() => classifyModerationResult(response(false, {
      illicit: null, "illicit/violent": null, [name]: null,
    })));
  }
  for (const name of ["illicit", "illicit/violent"]) {
    for (const value of [true, "false", 0, undefined]) {
      assert.throws(() => classifyModerationResult(response(false, { [name]: value })));
    }
  }
});

test("moderation parser routes self-harm intent to crisis response", () => {
  assert.equal(
    classifyModerationResult(response(true, { "self-harm/intent": true })),
    "crisis",
  );
});

test("moderation parser blocks other flagged content", () => {
  assert.equal(
    classifyModerationResult(response(true, { violence: true })),
    "block",
  );
});

test("moderation parser fails closed on malformed payloads", () => {
  assert.throws(() => classifyModerationResult({ results: [] }));
  assert.throws(() => classifyModerationResult({ results: [{}] }));
  assert.throws(() => classifyModerationResult({ results: [{ flagged: false, categories: {} }] }));
  assert.throws(() => classifyModerationResult(response(false, { violence: true })));
});
