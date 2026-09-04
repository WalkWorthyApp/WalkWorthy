import { test } from "node:test";
import assert from "node:assert/strict";
import { classifyModerationResult } from "../lib/content-safety";

function response(flagged: boolean, categories: Record<string, boolean>) {
  return { results: [{ flagged, categories }] };
}

test("moderation parser allows unflagged content", () => {
  assert.equal(classifyModerationResult(response(false, {})), "allow");
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
});
