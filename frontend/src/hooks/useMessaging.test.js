// Regression tests for the 20260830-compliance-remediation task's frontend
// fixes to useMessaging.js (dependency-errors #4 and #5, React stack only):
//
//   #5 — WS reconnect must back off exponentially (3s -> 30s cap, doubling
//        each failed attempt) instead of retrying immediately in a tight
//        loop, and must surface a "reconnecting…"/"offline" wsStatus rather
//        than failing silently.
//   #4 — a caught network/parse failure on a write action (openChat's fetch)
//        must surface a visible error via antd's `message.error`, not a
//        silent no-op.
//
// Run with: cd frontend && npm test -- --run src/hooks/useMessaging.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act, waitFor } from '@testing-library/react';
import { message } from 'antd';
import { useMessaging } from './useMessaging.js';

const USER = { user_id: 'user-1', username: 'tester' };

class MockWebSocket {
  static instances = [];
  constructor(url) {
    this.url = url;
    this.readyState = 0;
    this.onopen = null;
    this.onmessage = null;
    this.onerror = null;
    this.onclose = null;
    MockWebSocket.instances.push(this);
  }
  close() { this.readyState = 3; }
  send() {}
  // Test helpers, not part of the real WebSocket API.
  _open() { this.readyState = 1; this.onopen?.(); }
  _closeUnexpectedly() { this.readyState = 3; this.onclose?.(); }
}

beforeEach(() => {
  MockWebSocket.instances = [];
  global.WebSocket = MockWebSocket;
  global.fetch = vi.fn();
  vi.spyOn(message, 'error').mockImplementation(() => {});
  vi.spyOn(message, 'warning').mockImplementation(() => {});
  vi.spyOn(message, 'success').mockImplementation(() => {});
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe('useMessaging WS reconnect — exponential backoff (3s -> 30s cap)', () => {
  test('first reconnect attempt waits ~3s, not an immediate retry', () => {
    const { result } = renderHook(() => useMessaging({ user: USER }));
    act(() => { result.current.connectWS(); });
    expect(MockWebSocket.instances).toHaveLength(1);

    act(() => { MockWebSocket.instances[0]._closeUnexpectedly(); });
    // No new socket yet -- must wait out the backoff delay first.
    expect(MockWebSocket.instances).toHaveLength(1);

    act(() => { vi.advanceTimersByTime(2999); });
    expect(MockWebSocket.instances).toHaveLength(1);

    act(() => { vi.advanceTimersByTime(1); });
    expect(MockWebSocket.instances).toHaveLength(2);
  });

  test('delay doubles each consecutive failed attempt, capped at 30s', () => {
    const { result } = renderHook(() => useMessaging({ user: USER }));
    act(() => { result.current.connectWS(); });

    const expectedDelays = [3000, 6000, 12000, 24000, 30000, 30000]; // capped from the 5th attempt on
    for (const delay of expectedDelays) {
      const before = MockWebSocket.instances.length;
      act(() => { MockWebSocket.instances[before - 1]._closeUnexpectedly(); });
      expect(MockWebSocket.instances).toHaveLength(before); // still waiting

      act(() => { vi.advanceTimersByTime(delay - 1); });
      expect(MockWebSocket.instances).toHaveLength(before);

      act(() => { vi.advanceTimersByTime(1); });
      expect(MockWebSocket.instances).toHaveLength(before + 1);
    }
  });

  test('wsStatus is "reconnecting" for the first two failed attempts, then "offline"', () => {
    const { result } = renderHook(() => useMessaging({ user: USER }));
    act(() => { result.current.connectWS(); });

    act(() => { MockWebSocket.instances[0]._closeUnexpectedly(); });
    expect(result.current.wsStatus).toBe('reconnecting');

    act(() => { vi.advanceTimersByTime(3000); }); // 2nd socket opens attempt
    act(() => { MockWebSocket.instances[1]._closeUnexpectedly(); });
    expect(result.current.wsStatus).toBe('reconnecting');

    act(() => { vi.advanceTimersByTime(6000); }); // 3rd socket
    act(() => { MockWebSocket.instances[2]._closeUnexpectedly(); });
    expect(result.current.wsStatus).toBe('offline');
  });

  test('a successful reconnect resets the attempt counter and status to "connected"', () => {
    const { result } = renderHook(() => useMessaging({ user: USER }));
    act(() => { result.current.connectWS(); });
    act(() => { MockWebSocket.instances[0]._closeUnexpectedly(); });
    act(() => { vi.advanceTimersByTime(3000); });
    expect(MockWebSocket.instances).toHaveLength(2);

    act(() => { MockWebSocket.instances[1]._open(); });
    expect(result.current.wsStatus).toBe('connected');

    // Next failure after a successful reconnect must restart the backoff at
    // 3s, not continue escalating from the pre-reset attempt count.
    act(() => { MockWebSocket.instances[1]._closeUnexpectedly(); });
    act(() => { vi.advanceTimersByTime(2999); });
    expect(MockWebSocket.instances).toHaveLength(2);
    act(() => { vi.advanceTimersByTime(1); });
    expect(MockWebSocket.instances).toHaveLength(3);
  });

  test('disconnectWS (intentional close) does not schedule a reconnect', () => {
    const { result } = renderHook(() => useMessaging({ user: USER }));
    act(() => { result.current.connectWS(); });
    act(() => { result.current.disconnectWS(); });
    act(() => { vi.advanceTimersByTime(60000); });
    expect(MockWebSocket.instances).toHaveLength(1); // no reconnect socket created
  });
});

describe('useMessaging.openChat — surfaces a visible error on fetch failure (dependency-errors #4)', () => {
  test('a rejected fetch surfaces message.error instead of failing silently', async () => {
    vi.useRealTimers();
    global.fetch.mockRejectedValueOnce(new Error('network down'));
    const { result } = renderHook(() => useMessaging({ user: USER }));

    await act(async () => {
      await result.current.openChat({ id: 'friend-1', type: 'friend', toUsers: ['friend-1'] });
    });

    expect(message.error).toHaveBeenCalled();
  });
});
