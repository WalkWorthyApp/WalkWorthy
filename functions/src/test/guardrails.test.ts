/**
 * Regression tests for the PII output guardrail and the re-screen of stored
 * AI content.
 *
 * Runs with Node's built-in test runner: `npm test` (build + node --test).
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { containsPii, isCleanStoredAiContent } from "../lib/model-config";
import { CRISIS_RESPONSE } from "../lib/mood-agent";

// ============================================================================
// containsPii — regex classes
// ============================================================================

test("containsPii matches email addresses", () => {
  assert.equal(containsPii("write to sarah.jones@example.com today"), true);
});

test("containsPii matches URLs", () => {
  assert.equal(containsPii("see https://evil.example/steal for more"), true);
});

test("containsPii matches credential-shaped strings", () => {
  assert.equal(containsPii("key AKIA1234567890ABCDEF is live"), true);
});

test("containsPii matches phone numbers in common formats", () => {
  assert.equal(containsPii("call me at 555-123-4567"), true);
  assert.equal(containsPii("call (555) 123-4567 anytime"), true);
  assert.equal(containsPii("+1 555 123 4567"), true);
  assert.equal(containsPii("5551234567"), true);
});

test("containsPii does NOT match verse references", () => {
  assert.equal(containsPii("Philippians 4:6-7"), false);
  assert.equal(containsPii("John 3:16"), false);
  assert.equal(containsPii("Psalm 119:105 is a lamp"), false);
});

test("containsPii does NOT match ISO dates and timestamps", () => {
  assert.equal(containsPii("2026-07-05T18:00:00Z"), false);
  assert.equal(containsPii("generated on 2026-07-05"), false);
});

test("containsPii does NOT match clean encouragement prose", () => {
  assert.equal(
    containsPii(
      "Take heart — God sees every step you take, and Philippians 4:6-7 " +
        "reminds you to bring it all to Him in prayer.",
    ),
    false,
  );
});

// ============================================================================
// isCleanStoredAiContent — re-screening of cached/persisted responses
// ============================================================================

test("isCleanStoredAiContent passes clean stored content", () => {
  const stored = {
    reflection: "This week held both rain and light; God walked through both with you.",
    generatedAt: "2026-07-05T18:00:00Z",
    date: "2026-07-05",
  };
  assert.equal(isCleanStoredAiContent(stored), true);
});

test("isCleanStoredAiContent fails stored content with regex-class PII", () => {
  const stored = { message: "reach out to pastor@example.com" };
  assert.equal(isCleanStoredAiContent(stored), false);
});

test("stored crisis encouragement remains readable without changing its help card", () => {
  const before = JSON.stringify(CRISIS_RESPONSE);
  assert.equal(isCleanStoredAiContent(CRISIS_RESPONSE), true);
  assert.equal(JSON.stringify(CRISIS_RESPONSE), before);
});

test("reviewed support link never exempts unsafe prose or other resource fields", () => {
  for (const message of ["Email private@example.com", "Visit https://988lifeline.org"]) {
    assert.equal(isCleanStoredAiContent({ ...CRISIS_RESPONSE, message }), false);
  }
  assert.equal(isCleanStoredAiContent({
    ...CRISIS_RESPONSE,
    supportResource: { ...CRISIS_RESPONSE.supportResource, body: "Email private@example.com" },
  }), false);
});

test("unreviewed support URLs remain blocked even on purported fixed responses", () => {
  for (const url of ["https://example.com", "https://988lifeline.org.example.com", "https://988lifeline.org/private"]) {
    assert.equal(isCleanStoredAiContent({
      ...CRISIS_RESPONSE,
      supportResource: { ...CRISIS_RESPONSE.supportResource, url },
    }), false);
  }
});

test("Scripture with verse ranges passes the stored-content screen", () => {
  // "Romans 8:18-24" must not read as a phone number or other PII.
  const output = {
    message: "You are seen and known.",
    verseRef: "Romans 8:18-24",
    verseText: "So God created man in his own image... male and female he created them.",
  };
  assert.equal(isCleanStoredAiContent(output), true);
});
