import { test } from "node:test";
import assert from "node:assert/strict";
import {
  CRISIS_RESPONSE,
  BLOCKED_INPUT_RESPONSE,
  BLOCKED_OUTPUT_RESPONSE,
} from "../lib/mood-agent";

// Regression guard. A flagged MODEL OUTPUT means the model misbehaved — it
// says nothing about the user's state. Routing it to the crisis response
// sends an unprompted suicide-hotline referral to someone who wrote nothing
// concerning. Only a self-harm signal in the user's OWN note may do that.

test("only the crisis response carries a support resource", () => {
  assert.ok(CRISIS_RESPONSE.supportResource);
  assert.equal(BLOCKED_INPUT_RESPONSE.supportResource, undefined);
  assert.equal(BLOCKED_OUTPUT_RESPONSE.supportResource, undefined);
});

test("the crisis resource offers a reachable contact", () => {
  const resource = CRISIS_RESPONSE.supportResource;
  assert.ok(resource);
  assert.equal(resource.phone, "988");
  assert.match(resource.url ?? "", /^https:\/\//);
  assert.ok(resource.title.length > 0 && resource.body.length > 0);
});

test("no fallback response mentions a hotline in its message text", () => {
  // The number belongs in the resource card, not buried in prose that the
  // non-crisis fallbacks reuse.
  assert.doesNotMatch(BLOCKED_INPUT_RESPONSE.message, /988/);
  assert.doesNotMatch(BLOCKED_OUTPUT_RESPONSE.message, /988/);
});

test("every fallback still supplies a real catalog verse", () => {
  for (const response of [CRISIS_RESPONSE, BLOCKED_INPUT_RESPONSE, BLOCKED_OUTPUT_RESPONSE]) {
    assert.ok(response.verseRef.length > 0);
    assert.ok(response.verseText.length > 0);
    assert.equal(response.translation, "ESV");
  }
});
