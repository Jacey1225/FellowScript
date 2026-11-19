// Task 20261118-public-membership-page testing: pending purchase is an
// integer-only, clamped, 24h, sessionStorage handoff; postAuthPath never
// lands a web user on /reader (which redirects to /download).
import { describe, test, expect, beforeEach, afterEach } from 'vitest';
import {
  clampSeats, membershipPath, setPendingPurchase, getPendingPurchase,
  clearPendingPurchase, webSafeReaderPath, PENDING_PURCHASE_TTL_MS,
} from './pendingPurchase.js';
import { postAuthPath, setPendingInvite, setPendingExplore } from './pendingInvite.js';

beforeEach(() => sessionStorage.clear());
afterEach(() => { delete window.__TAURI_INTERNALS__; sessionStorage.clear(); });

describe('clampSeats / membershipPath', () => {
  test.each([
    ['5', 5], [5, 5], ['0', 1], [0, 1], ['101', 100], [100, 100], ['100', 100],
    ['abc', 1], [null, 1], [undefined, 1], ['-3', 1], ['2.5', 1], ['1e2', 1], ['99999', 1], [NaN, 1],
  ])('clampSeats(%j) -> %i', (input, out) => expect(clampSeats(input)).toBe(out));

  test('membershipPath is a fixed internal path with an integer only', () => {
    expect(membershipPath('7')).toBe('/membership?seats=7');
    expect(membershipPath('//evil.com&x=1')).toBe('/membership?seats=1');
    expect(membershipPath('https://evil.com')).toBe('/membership?seats=1');
  });
});

describe('pending purchase storage', () => {
  test('round trip, seats only', () => {
    setPendingPurchase(4);
    expect(getPendingPurchase()).toEqual({ seats: 4 });
    expect(Object.keys(JSON.parse(sessionStorage.getItem('fs_pending_purchase'))).sort()).toEqual(['at', 'seats']);
  });
  test('expires after 24h and is purged', () => {
    const now = 1_000_000;
    setPendingPurchase(3, now);
    expect(getPendingPurchase(now + PENDING_PURCHASE_TTL_MS)).toEqual({ seats: 3 });
    expect(getPendingPurchase(now + PENDING_PURCHASE_TTL_MS + 1)).toBeNull();
    expect(sessionStorage.getItem('fs_pending_purchase')).toBeNull();
  });
  test('tampered storage is discarded or re-clamped', () => {
    sessionStorage.setItem('fs_pending_purchase', '{bad');
    expect(getPendingPurchase()).toBeNull();
    sessionStorage.setItem('fs_pending_purchase', JSON.stringify({ seats: '/evil', at: Date.now() }));
    expect(getPendingPurchase()).toBeNull();
    sessionStorage.setItem('fs_pending_purchase', JSON.stringify({ seats: 5000, at: Date.now() }));
    expect(getPendingPurchase()).toEqual({ seats: 100 });
  });
  test('clear removes it', () => {
    setPendingPurchase(2); clearPendingPurchase();
    expect(getPendingPurchase()).toBeNull();
  });
});

describe('postAuthPath', () => {
  test('web default is /account, never /reader', () => {
    expect(postAuthPath()).toBe('/account');
    expect(webSafeReaderPath()).toBe('/');
  });
  test('pending purchase routes to /membership with seats', () => {
    setPendingPurchase(6);
    expect(postAuthPath()).toBe('/membership?seats=6');
  });
  test('precedence: invite > explore > purchase', () => {
    const tok = 'A'.repeat(43);
    setPendingPurchase(6);
    setPendingExplore('/explore/x');
    expect(postAuthPath()).toBe('/explore/x');
    setPendingPurchase(6);
    setPendingInvite(tok);
    expect(postAuthPath()).toBe(`/join/${tok}`);
  });
  test('desktop shell keeps /reader default', () => {
    window.__TAURI_INTERNALS__ = {};
    expect(postAuthPath()).toBe('/reader');
    expect(webSafeReaderPath()).toBe('/reader');
  });
});
