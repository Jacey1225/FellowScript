// Task 20261030-user-profiles testing step 8: in-memory profile cache.
import { describe, test, expect, beforeEach, vi } from 'vitest';
import { getCachedProfile, setCachedProfile, evictCachedProfile, clearProfileCache } from './profileCache.js';

beforeEach(() => clearProfileCache());

describe('profileCache', () => {
  test('miss returns null', () => {
    expect(getCachedProfile('v1', 't1')).toBeNull();
  });
  test('set then get', () => {
    setCachedProfile('v1', 't1', { username: 'ann' });
    expect(getCachedProfile('v1', 't1')).toEqual({ username: 'ann' });
  });
  test('keyed by viewer: another account never sees the first account\'s cached bio', () => {
    setCachedProfile('v1', 't1', { bio: 'private' });
    expect(getCachedProfile('v2', 't1')).toBeNull();
  });
  test('evict removes only that entry', () => {
    setCachedProfile('v1', 't1', { a: 1 });
    setCachedProfile('v1', 't2', { a: 2 });
    evictCachedProfile('v1', 't1');
    expect(getCachedProfile('v1', 't1')).toBeNull();
    expect(getCachedProfile('v1', 't2')).toEqual({ a: 2 });
  });
  test('clear (sign-out) empties everything', () => {
    setCachedProfile('v1', 't1', { a: 1 });
    setCachedProfile('v2', 't2', { a: 2 });
    clearProfileCache();
    expect(getCachedProfile('v1', 't1')).toBeNull();
    expect(getCachedProfile('v2', 't2')).toBeNull();
  });
  test('never touches web storage (memory only)', () => {
    const spy = { getItem: vi.fn(), setItem: vi.fn(), removeItem: vi.fn(), clear: vi.fn() };
    vi.stubGlobal('localStorage', spy);
    vi.stubGlobal('sessionStorage', spy);
    try {
      setCachedProfile('v1', 't1', { bio: 'x' });
      getCachedProfile('v1', 't1');
      evictCachedProfile('v1', 't1');
      clearProfileCache();
      expect(spy.setItem).not.toHaveBeenCalled();
      expect(spy.getItem).not.toHaveBeenCalled();
    } finally {
      vi.unstubAllGlobals();
    }
  });
});
