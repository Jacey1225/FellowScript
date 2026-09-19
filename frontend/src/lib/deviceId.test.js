// Tests for deviceId.js (task 20260918-admin-activity-monitoring): the
// client-side half of the visit-tracking device-identifier scheme security
// step 1 chose (client-generated UUIDv4, localStorage-persisted, regenerated
// if corrupted, falling back to an in-memory id if storage is unavailable).
//
// This repo's current jsdom/vitest environment has a pre-existing, unrelated
// bug where the bare `localStorage` global is a defined-but-undefined
// binding (see js/notes.delete-refresh.test.js's header comment and
// AppNav.desktop-scope.test.jsx) -- calling any of its methods throws a
// TypeError. That's exactly the "storage unavailable" case
// getOrCreateDeviceId's own try/catch is written to handle, so this file
// tests that fallback path directly against the real (broken) environment,
// and tests the persistence/regeneration paths against an explicit in-memory
// mock assigned over the same global -- it does not rely on the environment
// bug being fixed for either.
//
// Run with: cd frontend && npm test -- --run src/lib/deviceId.test.js
import { describe, test, expect, beforeEach, afterEach } from 'vitest';
import { getOrCreateDeviceId } from './deviceId.js';

const UUID_V4_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const STORAGE_KEY = 'fs_device_id';

function makeMockStorage() {
  const store = new Map();
  return {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
    clear: () => store.clear(),
  };
}

describe('getOrCreateDeviceId', () => {
  const originalDescriptor = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');

  afterEach(() => {
    if (originalDescriptor) {
      Object.defineProperty(globalThis, 'localStorage', originalDescriptor);
    } else {
      delete globalThis.localStorage;
    }
  });

  test('with a working store: generates a UUIDv4 and persists it', () => {
    const mock = makeMockStorage();
    Object.defineProperty(globalThis, 'localStorage', { value: mock, configurable: true });

    const id = getOrCreateDeviceId();
    expect(id).toMatch(UUID_V4_RE);
    expect(mock.getItem(STORAGE_KEY)).toBe(id);
  });

  test('with a working store: a second call returns the exact same id (persistence)', () => {
    const mock = makeMockStorage();
    Object.defineProperty(globalThis, 'localStorage', { value: mock, configurable: true });

    const first = getOrCreateDeviceId();
    const second = getOrCreateDeviceId();
    expect(second).toBe(first);
  });

  test('a corrupted/hand-edited stored value is discarded and replaced with a fresh valid UUIDv4', () => {
    const mock = makeMockStorage();
    mock.setItem(STORAGE_KEY, 'not-a-real-device-id');
    Object.defineProperty(globalThis, 'localStorage', { value: mock, configurable: true });

    const id = getOrCreateDeviceId();
    expect(id).toMatch(UUID_V4_RE);
    expect(id).not.toBe('not-a-real-device-id');
    expect(mock.getItem(STORAGE_KEY)).toBe(id);
  });

  test('storage unavailable (this environment\'s own undefined-localStorage bug): '
    + 'falls back to a valid in-memory UUIDv4 instead of throwing', () => {
    // Deliberately does NOT stub localStorage here -- exercising the real,
    // currently-broken environment global is the point (see file header).
    expect(() => getOrCreateDeviceId()).not.toThrow();
    const id = getOrCreateDeviceId();
    expect(id).toMatch(UUID_V4_RE);
  });

  test('storage that throws on every call (e.g. private-browsing quota lockdown) '
    + 'also falls back without throwing', () => {
    const throwing = {
      getItem: () => { throw new Error('SecurityError'); },
      setItem: () => { throw new Error('SecurityError'); },
    };
    Object.defineProperty(globalThis, 'localStorage', { value: throwing, configurable: true });

    expect(() => getOrCreateDeviceId()).not.toThrow();
    expect(getOrCreateDeviceId()).toMatch(UUID_V4_RE);
  });
});
