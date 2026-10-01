// Task 20260930-creator-friend-codes. Client helpers: pending-code carry-through
// (?code= capture, TTL, malformed rejection) and validate/friend-code calls
// (404 = flag off, uniform invalid, 429 limited).
// Run: cd frontend && npm test -- --run src/lib/promoCode.test.js
import { describe, test, expect, vi, beforeEach } from 'vitest';
import {
  normalizeCode, isWellFormedCode, savePendingCode, readPendingCode, clearPendingCode,
  captureCodeFromUrl, validatePromoCode, fetchFriendCode,
} from './promoCode.js';


// Node 26 ships its own (file-less, unusable) global localStorage that shadows
// jsdom's; install a plain in-memory Storage so the tests are runtime-independent.
function installMemoryStorage() {
  const m = new Map();
  vi.stubGlobal('localStorage', {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => { m.set(k, String(v)); },
    removeItem: (k) => { m.delete(k); },
    clear: () => { m.clear(); },
  });
}

beforeEach(() => {
  installMemoryStorage();
  localStorage.clear();
  window.history.replaceState({}, '', '/');
  global.fetch = vi.fn();
});

describe('code helpers', () => {
  test('normalize trims and uppercases', () => {
    expect(normalizeCode('  abc-12 ')).toBe('ABC-12');
    expect(normalizeCode(null)).toBe('');
  });
  test('well-formedness rejects junk and over-long input', () => {
    expect(isWellFormedCode('abc_12-X')).toBe(true);
    expect(isWellFormedCode('a b')).toBe(false);
    expect(isWellFormedCode('<script>')).toBe(false);
    expect(isWellFormedCode('')).toBe(false);
    expect(isWellFormedCode('x'.repeat(65))).toBe(false);
  });
});

describe('pending code carry-through', () => {
  test('save then read returns the uppercased code', () => {
    expect(savePendingCode('friend123')).toBe(true);
    expect(readPendingCode()).toBe('FRIEND123');
  });
  test('malformed code is not stored', () => {
    expect(savePendingCode('bad code!')).toBe(false);
    expect(readPendingCode()).toBe('');
  });
  test('expires after 7 days and is removed', () => {
    savePendingCode('ABC', 1000);
    expect(readPendingCode(1000 + 7 * 24 * 3600 * 1000 - 1)).toBe('ABC');
    expect(readPendingCode(1000 + 7 * 24 * 3600 * 1000 + 1)).toBe('');
    expect(localStorage.getItem('fs_pending_promo_code')).toBeNull();
  });
  test('tampered storage yields no code', () => {
    localStorage.setItem('fs_pending_promo_code', '{not json');
    expect(readPendingCode()).toBe('');
    localStorage.setItem('fs_pending_promo_code', JSON.stringify({ code: '<x>', at: Date.now() }));
    expect(readPendingCode()).toBe('');
  });
  test('clear removes it', () => {
    savePendingCode('ABC'); clearPendingCode();
    expect(readPendingCode()).toBe('');
  });
});

describe('captureCodeFromUrl', () => {
  test('stores ?code= and strips it from the URL, keeping other params and the hash', () => {
    window.history.replaceState({}, '', '/?code=sharedabc&utm=x#/account');
    captureCodeFromUrl();
    expect(readPendingCode()).toBe('SHAREDABC');
    expect(window.location.search).toBe('?utm=x');
    expect(window.location.hash).toBe('#/account');
  });
  test('no code param leaves storage untouched', () => {
    window.history.replaceState({}, '', '/?utm=x');
    captureCodeFromUrl();
    expect(readPendingCode()).toBe('');
  });
  test('malformed ?code= is dropped from the URL but not stored', () => {
    window.history.replaceState({}, '', '/?code=a%20b%3Cx');
    captureCodeFromUrl();
    expect(readPendingCode()).toBe('');
    expect(window.location.search).toBe('');
  });
});

describe('validatePromoCode', () => {
  const res = (status, body) => ({ ok: status >= 200 && status < 300, status, json: async () => body });
  test('valid -> enabled + percent', async () => {
    global.fetch.mockResolvedValueOnce(res(200, { valid: true, percent_off: 50 }));
    expect(await validatePromoCode('u1', 'ABC', 1)).toEqual({ enabled: true, valid: true, percentOff: 50 });
    const [url, init] = global.fetch.mock.calls[0];
    expect(url).toMatch(/\/promo\/u1\/validate$/);
    expect(JSON.parse(init.body)).toEqual({ code: 'ABC', member_count: 1 });
  });
  test('404 means feature flag off', async () => {
    global.fetch.mockResolvedValueOnce(res(404, {}));
    expect(await validatePromoCode('u1', '', 1)).toEqual({ enabled: false, valid: false });
  });
  test('{valid:false} -> enabled but invalid', async () => {
    global.fetch.mockResolvedValueOnce(res(200, { valid: false }));
    const r = await validatePromoCode('u1', 'X', 1);
    expect(r.enabled).toBe(true); expect(r.valid).toBe(false);
  });
  test('only literal valid:true counts (truthy strings do not)', async () => {
    global.fetch.mockResolvedValueOnce(res(200, { valid: 'true' }));
    expect((await validatePromoCode('u1', 'X', 1)).valid).toBe(false);
  });
  test('429 -> limited, still enabled', async () => {
    global.fetch.mockResolvedValueOnce(res(429, {}));
    expect(await validatePromoCode('u1', 'X', 1)).toMatchObject({ enabled: true, valid: false, limited: true });
  });
  test('server error / network failure fail closed (hidden, invalid)', async () => {
    global.fetch.mockResolvedValueOnce(res(500, {}));
    expect(await validatePromoCode('u1', 'X', 1)).toMatchObject({ enabled: false, valid: false });
    global.fetch.mockRejectedValueOnce(new Error('down'));
    expect(await validatePromoCode('u1', 'X', 1)).toMatchObject({ enabled: false, valid: false });
  });
});

describe('fetchFriendCode', () => {
  test('returns data; throws on non-ok or malformed', async () => {
    global.fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ code: 'ABCDEFGHJK', link: 'l' }) });
    expect((await fetchFriendCode('u1')).code).toBe('ABCDEFGHJK');
    global.fetch.mockResolvedValueOnce({ ok: false, status: 404, json: async () => ({}) });
    await expect(fetchFriendCode('u1')).rejects.toThrow();
    global.fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ nope: 1 }) });
    await expect(fetchFriendCode('u1')).rejects.toThrow();
  });
});
