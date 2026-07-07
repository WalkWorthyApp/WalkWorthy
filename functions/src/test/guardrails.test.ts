/**
 * Regression tests for the PII output guardrail and the profile echo-check
 * (added after a Codex adversarial review found the regex-only guardrail
 * couldn't catch the model repeating profile values back to the user).
 *
 * Runs with Node's built-in test runner: `npm test` (build + node --test).
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  containsPii,
  assertNoProfileEcho,
  GuardrailTripError,
} from "../lib/model-config";
import { collectProfileValues } from "../lib/profile-sanitize";
import type { UserProfilePayload } from "../lib/profile-sanitize";

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
// assertNoProfileEcho
// ============================================================================

test("assertNoProfileEcho trips on an echoed occupation", () => {
  const output = {
    message: "As a nursing student you already carry others' burdens.",
    verseRef: "Galatians 6:2",
  };
  assert.throws(
    () => assertNoProfileEcho(output, ["nursing student"]),
    GuardrailTripError,
  );
});

test("assertNoProfileEcho trips on an echoed custom hobby", () => {
  const output = { reflection: "Your varsity soccer season mirrors your walk." };
  assert.throws(
    () => assertNoProfileEcho(output, ["varsity soccer"]),
    GuardrailTripError,
  );
});

test("assertNoProfileEcho is case-insensitive", () => {
  assert.throws(
    () => assertNoProfileEcho({ message: "ENGINEERING is your calling" }, ["engineering"]),
    GuardrailTripError,
  );
});

test("assertNoProfileEcho does not trip on clean output", () => {
  assert.doesNotThrow(() =>
    assertNoProfileEcho(
      { message: "God is near to the brokenhearted.", verseRef: "Psalm 34:18" },
      ["engineering", "varsity soccer", "18-24"],
    ),
  );
});

test("assertNoProfileEcho skips values shorter than 4 characters", () => {
  assert.doesNotThrow(() =>
    assertNoProfileEcho({ message: "art and heart alike" }, ["art"]),
  );
});

test("assertNoProfileEcho uses whole-word matching (Male vs female)", () => {
  assert.doesNotThrow(() =>
    assertNoProfileEcho({ message: "every female student here" }, ["Male"]),
  );
  assert.throws(
    () => assertNoProfileEcho({ message: "as a male student" }, ["Male"]),
    GuardrailTripError,
  );
});

test("assertNoProfileEcho handles regex special characters in values", () => {
  assert.doesNotThrow(() =>
    assertNoProfileEcho({ message: "clean text" }, ["C++ (competitive)"]),
  );
  assert.throws(
    () => assertNoProfileEcho({ message: "your C++ (competitive) skills" }, ["C++ (competitive)"]),
    GuardrailTripError,
  );
});

// ============================================================================
// collectProfileValues
// ============================================================================

const baseProfile: UserProfilePayload = {
  ageRange: "18-24",
  gender: "female",
  occupation: "Nurse",
  major: "Nursing",
  hobbies: ["Worship", "Music", "competitive fencing"],
  optInTailored: true,
};

test("collectProfileValues includes identity fields and custom hobbies", () => {
  const values = collectProfileValues(baseProfile);
  assert.ok(values.includes("Nurse"));
  assert.ok(values.includes("Nursing"));
  assert.ok(values.includes("female"));
  assert.ok(values.includes("18-24"));
  assert.ok(values.includes("competitive fencing"));
});

test("collectProfileValues excludes preset hobby vocabulary", () => {
  const values = collectProfileValues(baseProfile);
  assert.equal(values.includes("Worship"), false);
  assert.equal(values.includes("Music"), false);
});

test("collectProfileValues returns empty for null profile", () => {
  assert.deepEqual(collectProfileValues(null), []);
});
