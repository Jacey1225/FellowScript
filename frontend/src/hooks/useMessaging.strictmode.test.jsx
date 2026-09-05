// Regression test for task 20260904-compliance-reliability-bugs's fix to
// useMessaging.js's WS onmessage handler: the setMessages side effect used
// to live inside a setCurrentContact(cc => { setMessages(...); return cc; })
// updater -- calling another state setter from inside a different setter's
// updater function is impure, and React 18 StrictMode's intentional
// double-invocation of updater functions in development could fire that
// side effect twice, duplicating the incoming chat bubble. The fix reads
// currentContact from a ref instead and never calls setCurrentContact from
// this handler at all, so setMessages runs exactly once per incoming
// message regardless of StrictMode's double-invocation behavior.
//
// Run with: cd frontend && npm test -- --run src/hooks/useMessaging.strictmode.test.js
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { message } from 'antd';
import { useMessaging } from './useMessaging.js';

const USER = { user_id: 'user-1', username: 'tester' };
const CONTACT = { id: 'friend-1', type: 'friend', toUsers: ['friend-1'], group_id: '' };

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
  _open() { this.readyState = 1; this.onopen?.(); }
  _receive(data) { this.onmessage?.({ data: JSON.stringify(data) }); }
}

beforeEach(() => {
  MockWebSocket.instances = [];
  global.WebSocket = MockWebSocket;
  global.fetch = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ host_msgs: [], other_msgs: [] }) });
  vi.spyOn(message, 'error').mockImplementation(() => {});
  vi.spyOn(message, 'warning').mockImplementation(() => {});
  vi.spyOn(message, 'success').mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('useMessaging WS onmessage — setMessages is not nested inside another setter\'s updater (React 18 StrictMode safe)', () => {
  test('one incoming message under React.StrictMode appends exactly one chat bubble, not two', async () => {
    const wrapper = ({ children }) => <React.StrictMode>{children}</React.StrictMode>;
    const { result } = renderHook(() => useMessaging({ user: USER }), { wrapper });

    await act(async () => { await result.current.openChat(CONTACT); });
    act(() => { result.current.connectWS(); });
    act(() => { MockWebSocket.instances[0]._open(); });

    act(() => {
      MockWebSocket.instances[0]._receive({
        type: 'message',
        from_user: 'friend-1',
        group_id: '',
        text: 'hello there',
        timestamp: '2026-09-04T12:00:00Z',
      });
    });

    expect(result.current.messages).toHaveLength(1);
    expect(result.current.messages[0].text).toBe('hello there');
  });

  test('two distinct incoming messages append exactly two bubbles in order', async () => {
    const wrapper = ({ children }) => <React.StrictMode>{children}</React.StrictMode>;
    const { result } = renderHook(() => useMessaging({ user: USER }), { wrapper });

    await act(async () => { await result.current.openChat(CONTACT); });
    act(() => { result.current.connectWS(); });
    act(() => { MockWebSocket.instances[0]._open(); });

    act(() => {
      MockWebSocket.instances[0]._receive({ type: 'message', from_user: 'friend-1', group_id: '', text: 'first', timestamp: 't1' });
    });
    act(() => {
      MockWebSocket.instances[0]._receive({ type: 'message', from_user: 'friend-1', group_id: '', text: 'second', timestamp: 't2' });
    });

    expect(result.current.messages.map(m => m.text)).toEqual(['first', 'second']);
  });
});
