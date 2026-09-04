import { test } from "node:test";
import assert from "node:assert/strict";
import {
  SCRIPTURE_CATALOG,
  SCRIPTURE_IDS,
  resolveScripture,
} from "../lib/scripture-catalog";

test("catalog IDs resolve to non-empty reviewed passages", () => {
  assert.ok(SCRIPTURE_IDS.length >= 10);
  for (const id of SCRIPTURE_IDS) {
    const passage = resolveScripture(id);
    assert.ok(passage);
    assert.ok(passage.ref.trim().length > 0);
    assert.ok(passage.text.trim().length > 0);
  }
});

test("unknown catalog IDs cannot resolve", () => {
  assert.equal(resolveScripture("made_up_verse"), undefined);
});

test("catalog references are unique", () => {
  const references = Object.values(SCRIPTURE_CATALOG).map((entry) => entry.ref);
  assert.equal(new Set(references).size, references.length);
});
