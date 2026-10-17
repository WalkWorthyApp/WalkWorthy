import assert from 'node:assert/strict';
import test from 'node:test';
import { validateTimeZone, validateUserProfileInput } from '../shared/types';
import { getLogicalDateString } from '../shared/time';

test('accepts IANA-shaped zones, including ones this runtime may not know yet', () => {
  for (const zone of ['America/New_York', 'UTC', 'GMT', 'Asia/Calcutta', 'Asia/Kyiv', 'Etc/GMT+5', 'GMT+0530',
    'America/Argentina/Buenos_Aires', 'America/Port-au-Prince']) {
    assert.equal(validateTimeZone(zone), zone);
  }
});

test('rejects malformed zones, oversized strings, and non-strings', () => {
  for (const value of ['../../profile', 'America/../profile', 'America/New_York\n', 'America/New York', '/UTC', 'UTC/',
    'America//New_York', '+05:00', '', 'A'.repeat(51), null, undefined, 5, ['UTC'], {}]) {
    assert.equal(validateTimeZone(value), undefined, JSON.stringify(value));
  }
});

test('profile input requires a well-formed time zone', () => {
  assert.equal(validateUserProfileInput({ ageRange: '18-24', timezone: '../etc' }), undefined);
  assert.equal(validateUserProfileInput({ ageRange: '18-24', timezone: 'Europe/London' })?.timezone, 'Europe/London');
});

test('a stored zone the runtime does not recognize buckets dates in UTC', t => {
  t.mock.timers.enable({ apis: ['Date'], now: new Date('2026-10-08T12:00:00Z') });
  assert.equal(getLogicalDateString('Not/AZone'), '2026-10-08');
  t.mock.timers.reset();
  t.mock.timers.enable({ apis: ['Date'], now: new Date('2026-10-08T01:00:00Z') });
  assert.equal(getLogicalDateString('Not/AZone'), '2026-10-07', 'hours 0-2 belong to the previous UTC day');
});
