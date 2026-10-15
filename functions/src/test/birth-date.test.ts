import assert from 'node:assert/strict';
import test from 'node:test';
import { validateBirthDate } from '../shared/types';

// Noon UTC on Oct 14, 2026: Oct 14 has begun everywhere (it is 00:00 in UTC-12).
const now = new Date('2026-10-14T12:00:00Z');

test('accepts real adult birth dates', () => {
  assert.equal(validateBirthDate('1998-03-07', now), '1998-03-07');
  assert.equal(validateBirthDate('1900-01-01', now), '1900-01-01');
  assert.equal(validateBirthDate('2000-02-29', now), '2000-02-29');
});

test('enforces the 18+ minimum on the earliest calendar day on Earth', () => {
  assert.equal(validateBirthDate('2008-10-14', now), '2008-10-14', '18 today everywhere');
  assert.equal(validateBirthDate('2008-10-15', now), undefined, 'still 17 in UTC-12 to UTC+11');
  assert.equal(validateBirthDate('2008-10-15', new Date('2026-10-15T11:59:00Z')), undefined, 'still 17 in UTC-12');
  assert.equal(validateBirthDate('2008-10-15', new Date('2026-10-15T12:00:00Z')), '2008-10-15', '18 everywhere');
  assert.equal(validateBirthDate('2010-01-01', now), undefined);
  assert.equal(validateBirthDate('2030-01-01', now), undefined, 'future');
});

test('rejects impossible dates and malformed input', () => {
  for (const value of ['1999-02-29', '1999-02-30', '1999-13-01', '1999-00-10', '1999-04-31', '1899-12-31',
    '99-01-01', '1999-1-01', '1999/01/01', '1999-01-01T00:00:00Z', ' 1999-01-01', '', null, 19990101, {}]) {
    assert.equal(validateBirthDate(value, now), undefined, String(value));
  }
});
