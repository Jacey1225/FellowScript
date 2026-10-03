// Task 20261003-web-reader-ios-parity step 1. Run: npm test -- --run src/lib/sessionAccess.test.js
import { describe, test, expect } from 'vitest';
import { isJoinWindowOpen, isSessionHost, JOIN_GRACE_MINUTES } from './sessionAccess.js';

const NOW = Date.parse('2026-10-03T12:00:00Z');
const MIN = 60e3;
const at = off => new Date(NOW + off).toISOString();

describe('isJoinWindowOpen', () => {
  test('closed before the grace window, open exactly at its start', () => {
    const closed = { time_start: at((JOIN_GRACE_MINUTES * MIN) + 1000) };
    const open = { time_start: at(JOIN_GRACE_MINUTES * MIN) };
    expect(isJoinWindowOpen(closed, NOW)).toBe(false);
    expect(isJoinWindowOpen(open, NOW)).toBe(true);
  });
  test('open during the session and at the end boundary, closed after', () => {
    expect(isJoinWindowOpen({ time_start: at(-5 * MIN), time_end: at(5 * MIN) }, NOW)).toBe(true);
    expect(isJoinWindowOpen({ time_start: at(-5 * MIN), time_end: at(0) }, NOW)).toBe(true);
    expect(isJoinWindowOpen({ time_start: at(-5 * MIN), time_end: at(-1) }, NOW)).toBe(false);
  });
  test('missing or end-less sessions: open-ended once started', () => {
    expect(isJoinWindowOpen({ time_start: at(-5 * MIN), time_end: '' }, NOW)).toBe(true);
    expect(isJoinWindowOpen({ time_start: at(-5 * MIN), time_end: 'garbage' }, NOW)).toBe(true);
  });
  test('fails closed on missing or malformed time_start', () => {
    expect(isJoinWindowOpen({}, NOW)).toBe(false);
    expect(isJoinWindowOpen({ time_start: '' }, NOW)).toBe(false);
    expect(isJoinWindowOpen({ time_start: 'not a date' }, NOW)).toBe(false);
    expect(isJoinWindowOpen(null, NOW)).toBe(false);
  });
});

describe('isSessionHost', () => {
  test('true only when creator_id equals user_id', () => {
    expect(isSessionHost({ creator_id: 'u1' }, { user_id: 'u1' })).toBe(true);
    expect(isSessionHost({ creator_id: 'u2' }, { user_id: 'u1' })).toBe(false);
  });
  test('fails closed on empty or missing ids', () => {
    expect(isSessionHost({ creator_id: '' }, { user_id: '' })).toBe(false);
    expect(isSessionHost({}, { user_id: 'u1' })).toBe(false);
    expect(isSessionHost({ creator_id: 'u1' }, null)).toBe(false);
    expect(isSessionHost(null, null)).toBe(false);
  });
});
