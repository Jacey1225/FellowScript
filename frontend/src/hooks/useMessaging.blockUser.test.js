// Regression test for task 20260904-compliance-error-handling-consistency's
// fix to useMessaging.js (dependency-errors #8): blockUser() was the one
// action in this file with no user-facing failure feedback at all -- a
// failed block (non-ok response or thrown network error) previously just
// silently returned false with nothing shown to the user. It now surfaces
// a visible antd `message.error` on both failure paths, matching the rest
// of the file's reportUser/removeFriend conventions.
//
// Run with: cd frontend && npm test -- --run src/hooks/useMessaging.blockUser.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { message } from 'antd';
import { useMessaging } from './useMessaging.js';

const USER = { user_id: 'user-1', username: 'tester' };

class MockWebSocket {
  constructor() {
    this.readyState = 0;
    this.onopen = null;
    this.onmessage = null;
    this.onerror = null;
    this.onclose = null;
  }
  close() { this.readyState = 3; }
  send() {}
}

beforeEach(() => {
  global.WebSocket = MockWebSocket;
  global.fetch = vi.fn();
  vi.spyOn(message, 'error').mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('useMessaging.blockUser — surfaces a visible error on failure (dependency-errors #8)', () => {
  test('a non-ok response surfaces message.error and returns false', async () => {
    global.fetch.mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) });
    const { result } = renderHook(() => useMessaging({ user: USER }));

    let ok;
    await act(async () => { ok = await result.current.blockUser('blocked-user-1'); });

    expect(ok).toBe(false);
    expect(message.error).toHaveBeenCalled();
  });

  test('a rejected fetch (network failure) surfaces message.error and returns false', async () => {
    global.fetch.mockRejectedValueOnce(new Error('network down'));
    const { result } = renderHook(() => useMessaging({ user: USER }));

    let ok;
    await act(async () => { ok = await result.current.blockUser('blocked-user-1'); });

    expect(ok).toBe(false);
    expect(message.error).toHaveBeenCalled();
  });

  test('a successful (200) block does not surface an error and returns true', async () => {
    global.fetch.mockResolvedValueOnce({ ok: true, status: 200, json: async () => ({}) });
    const { result } = renderHook(() => useMessaging({ user: USER }));

    let ok;
    await act(async () => { ok = await result.current.blockUser('blocked-user-1'); });

    expect(ok).toBe(true);
    expect(message.error).not.toHaveBeenCalled();
  });

  test('a successful (204) block also does not surface an error and returns true', async () => {
    global.fetch.mockResolvedValueOnce({ ok: false, status: 204, json: async () => ({}) });
    const { result } = renderHook(() => useMessaging({ user: USER }));

    let ok;
    await act(async () => { ok = await result.current.blockUser('blocked-user-1'); });

    expect(ok).toBe(true);
    expect(message.error).not.toHaveBeenCalled();
  });
});
