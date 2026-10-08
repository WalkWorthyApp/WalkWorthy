import { test } from 'node:test';
import assert from 'node:assert/strict';
import { NOTICE_VERSION, parseConsent, validateConsentInput } from '../shared/privacy-consent';
import { validateUserProfileInput } from '../shared/types';
const grant = {aiSharing: true, noticeVersion: NOTICE_VERSION, ageGroup: '18+', expectedRevision: 0};
test('consent fails closed for missing, legacy and malformed records', () => {
  for (const value of [undefined, {}, {aiSharing: true}, {aiSharing: 'true'},
    {aiSharing: true, ageGroup: '18+', noticeVersion: 'old', revision: 1},
    {aiSharing: true, ageGroup: 'unknown', noticeVersion: NOTICE_VERSION, revision: 1},
    {aiSharing: true, ageGroup: '13-17', noticeVersion: NOTICE_VERSION, revision: 1},
    {aiSharing: true, ageGroup: '18+', noticeVersion: NOTICE_VERSION, revision: -1}]) {
    assert.equal(parseConsent(value).aiSharing, false);
  }
  assert.deepEqual(parseConsent(), {aiSharing: false, noticeVersion: NOTICE_VERSION, ageGroup: 'unknown', revision: 0, updatedAt: null});
});
test('consent grants require explicit Boolean, notice, valid age group and safe CAS revision', () => {
  assert.ok(validateConsentInput(grant));
  // WalkWorthy is adults-only. A minor declaration is not a downgraded grant,
  // it is not a grant at all — neither on input nor on a stored record.
  for (const patch of [{aiSharing: 'false'}, {aiSharing: 1}, {ageGroup: undefined}, {ageGroup: '13-17'}, {ageGroup: 'unknown'}, {noticeVersion: 'old'}, {expectedRevision: -1}, {expectedRevision: 0.1}, {expectedRevision: Number.MAX_SAFE_INTEGER}, {withdrawalId: '00000000-0000-4000-8000-000000000000'}, {extra: true}]) {
    assert.equal(validateConsentInput({...grant, ...patch}), null);
  }
});
test('withdrawal requires no preflight revision, notice, or age assertion', () => {
  assert.deepEqual(validateConsentInput({aiSharing: false}), {aiSharing: false});
  assert.ok(validateConsentInput({aiSharing: false, noticeVersion: NOTICE_VERSION, expectedRevision: 1}));
  assert.deepEqual(validateConsentInput({aiSharing: false, noticeVersion: 'old', expectedRevision: 0}), {aiSharing: false});
  const withdrawalId = 'ABCDEFAB-0000-4000-8000-000000000000';
  assert.deepEqual(validateConsentInput({aiSharing: false, withdrawalId}), {aiSharing: false, withdrawalId: withdrawalId.toLowerCase()});
  for (const patch of [{extra: true}, {expectedRevision: '0'}, {ageGroup: ['18+']}, {noticeVersion: 1}, {withdrawalId: ''}, {withdrawalId: 1}, {withdrawalId: 'not-a-uuid'}]) {
    assert.equal(validateConsentInput({aiSharing: false, ...patch}), null);
  }
});
test('profile opt-in never coerces values to consent', () => {
  const base = {ageRange: '18-24', timezone: 'America/New_York', hobbies: []};
  for (const value of ['false', 'true', 1, 0, null, undefined, [], {}]) {
    assert.equal(validateUserProfileInput({...base, optInTailored: value}), undefined);
  }
  assert.equal(validateUserProfileInput({...base, optInTailored: false})?.optInTailored, false);
  assert.equal(validateUserProfileInput({...base, optInTailored: true})?.optInTailored, true);
});
