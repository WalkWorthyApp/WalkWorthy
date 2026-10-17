import assert from 'node:assert/strict';
import test from 'node:test';
import { validateTimeZone, validateUserProfileInput } from '../shared/types';

test('accepts IANA time zones, including aliases the app may report', () => {
  for (const zone of ['America/New_York', 'UTC', 'GMT', 'Asia/Calcutta', 'Asia/Kolkata', 'Etc/GMT+5', 'America/Argentina/Buenos_Aires']) {
    assert.equal(validateTimeZone(zone), zone);
  }
});

test('rejects unknown zones, oversized strings, and non-strings', () => {
  for (const value of ['Not/AZone', '../../profile', 'America/New_York\n', '', 'x'.repeat(51), null, undefined, 5, ['UTC'], {}]) {
    assert.equal(validateTimeZone(value), undefined, JSON.stringify(value));
  }
});

test('profile input requires a valid time zone', () => {
  assert.equal(validateUserProfileInput({ ageRange: '18-24', timezone: 'Mars/Olympus_Mons' }), undefined);
  assert.equal(validateUserProfileInput({ ageRange: '18-24', timezone: 'Europe/London' })?.timezone, 'Europe/London');
});
