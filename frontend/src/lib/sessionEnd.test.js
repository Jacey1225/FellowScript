// Task 20261017-chat-ws-reconnect-stuck: session-ended detection (web/desktop).
// Run with: cd frontend && npm test -- --run src/lib/sessionEnd.test.js
import { describe, test, expect, vi, beforeEach } from 'vitest';
import { API } from '../config.js';
import {
  isUnauthenticatedPath, shouldMarkSessionEnded, probeSession, backoffDelay,
  markSessionEnded, resetSessionEnded, isSessionEnded, subscribeSessionEnded,
  installSessionGuard,
} from './sessionEnd.js';

const API_BASE = 'https://fellowscript.com/api';

beforeEach(() => resetSessionEnded());

describe('probeSession', () => {
  test('401 means the session ended', async () => {
    expect(await probeSession('u1', async () => ({ status: 401 }), API_BASE)).toBe('ended');
  });
  test('success, server error, no response, and network failure all mean keep reconnecting', async () => {
    expect(await probeSession('u1', async () => ({ status: 200 }), API_BASE)).toBe('alive');
    expect(await probeSession('u1', async () => ({ status: 503 }), API_BASE)).toBe('alive');
    expect(await probeSession('u1', async () => undefined, API_BASE)).toBe('alive');
    expect(await probeSession('u1', async () => { throw new TypeError('Failed to fetch'); }, API_BASE)).toBe('alive');
  });
  test('403 is not treated as session end (only 401)', async () => {
    expect(await probeSession('u1', async () => ({ status: 403 }), API_BASE)).toBe('alive');
  });
  test('probes the existing current-user call with credentials', async () => {
    const f = vi.fn(async () => ({ status: 200 }));
    await probeSession('abc', f, API_BASE);
    expect(f).toHaveBeenCalledWith(`${API_BASE}/user/abc`, { credentials: 'include' });
  });
});

describe('401 path rules', () => {
  test('pre-login and public endpoints never mark the session ended', () => {
    for (const p of ['/login', '/login/', '/signup/', '/logout/', '/auth/google', '/auth/apple',
      '/auth/mfa/verify-login', '/auth/mfa/disable', '/auth/password-reset/request',
      '/app/capabilities', '/invites/preview/tok', '/explorer/config', '/explorer/listings/abc']) {
      expect(shouldMarkSessionEnded(401, `${API_BASE}${p}`, API_BASE), p).toBe(false);
    }
  });
  test('only 401 on an authenticated API path marks it', () => {
    expect(shouldMarkSessionEnded(401, `${API_BASE}/user/u1`, API_BASE)).toBe(true);
    expect(shouldMarkSessionEnded(401, `${API_BASE}/groups/u1/g1?limit=1`, API_BASE)).toBe(true);
    expect(shouldMarkSessionEnded(403, `${API_BASE}/user/u1`, API_BASE)).toBe(false);
    expect(shouldMarkSessionEnded(500, `${API_BASE}/user/u1`, API_BASE)).toBe(false);
    expect(shouldMarkSessionEnded(401, 'https://other.example/user/u1', API_BASE)).toBe(false);
  });
  test('isUnauthenticatedPath ignores query strings', () => {
    expect(isUnauthenticatedPath('/auth/mfa/disable?x=1')).toBe(true);
    expect(isUnauthenticatedPath('/auth/mfa/enable')).toBe(false);
  });
});

describe('latch', () => {
  test('a burst of marks notifies once; reset re-arms', () => {
    const cb = vi.fn();
    const off = subscribeSessionEnded(cb);
    expect(markSessionEnded()).toBe(true);
    expect(markSessionEnded()).toBe(false);
    expect(markSessionEnded()).toBe(false);
    expect(isSessionEnded()).toBe(true);
    expect(cb).toHaveBeenCalledTimes(1);
    resetSessionEnded();
    expect(isSessionEnded()).toBe(false);
    off();
  });
});

describe('fetch guard', () => {
  test('latches on an authenticated 401, returns the 401 untouched, ignores pre-login 401', async () => {
    const res401 = { status: 401 };
    const target = { fetch: vi.fn(async () => res401) };
    installSessionGuard(target);
    expect(await target.fetch(`${API}/login/`)).toBe(res401);
    expect(isSessionEnded()).toBe(false);
    expect(await target.fetch(`${API}/notes/u1`)).toBe(res401);
    expect(isSessionEnded()).toBe(true);
  });
});

describe('fetch guard: a signed-in user\'s wrong credential never reads as "session ended"', () => {
  // Fresh module copy so the guard installs on a throwaway target.
  test('401 from the five non-session 401 routes never latches; a real session 401 still does', async () => {
    vi.resetModules();
    const mod = await import('./sessionEnd.js');
    const { API: base } = await import('../config.js');
    const res401 = { status: 401 };
    const target = { fetch: vi.fn(async () => res401) };
    mod.installSessionGuard(target);
    for (const p of ['/login', '/auth/mfa/verify-login', '/auth/mfa/disable', '/auth/google', '/auth/apple']) {
      expect(await target.fetch(`${base}${p}`, { method: 'POST' }), p).toBe(res401);
      expect(mod.isSessionEnded(), p).toBe(false);
    }
    expect(await target.fetch(`${base}/auth/mfa/enable`, { method: 'POST' })).toBe(res401);
    expect(mod.isSessionEnded()).toBe(true);
  });
});

describe('reconnect backoff keeps the 3s -> 30s cap', () => {
  test('doubles then caps', () => {
    expect([1, 2, 3, 4, 5, 6, 7].map((n) => backoffDelay(n))).toEqual([3000, 6000, 12000, 24000, 30000, 30000, 30000]);
  });
});
