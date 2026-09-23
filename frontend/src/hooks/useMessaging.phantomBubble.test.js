// Regression coverage for task 20260923-chat-phantom-empty-bubbles.
//
// Root cause: useMessaging.js's WS `onmessage` handler treated any frame
// whose `type` wasn't in SESSION_TYPES as an ordinary inbound chat message,
// with no from_user/text/timestamp validation -- so a backend
// `{"type":"ping"}` heartbeat (ConnectionManager.HEARTBEAT_INTERVAL, every
// 25s) or `{"type":"error",...}` frame (a rejected/failed send) got appended
// to `messages` as a contentless bubble whenever the open thread was a DM.
// This mirrors the fix already shipped for iOS under task
// 20260910-chat-message-disappear-reentry.
//
// Run with: cd frontend && npm test -- --run src/hooks/useMessaging.phantomBubble.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { message } from 'antd';
import { useMessaging } from './useMessaging.js';

const USER = { user_id: 'u1', username: 'tester' };
const SENDER = { user_id: 'friend-1', username: 'ada' };

class MockWebSocket {
  static instances = [];
  constructor(url) {
    this.url = url;
    this.readyState = 1;
    this.sent = [];
    this.onopen = null; this.onmessage = null; this.onerror = null; this.onclose = null;
    MockWebSocket.instances.push(this);
  }
  close() { this.readyState = 3; }
  send(data) { this.sent.push(data); }
}

beforeEach(() => {
  MockWebSocket.instances = [];
  global.WebSocket = MockWebSocket;
  global.fetch = vi.fn();
  vi.spyOn(message, 'error').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

async function connectedToDM() {
  global.fetch.mockResolvedValueOnce({ ok: true, json: async () => ({ host_msgs: [], other_msgs: [] }) });
  const { result } = renderHook(() => useMessaging({ user: USER }));
  act(() => { result.current.connectWS(); });
  await act(async () => { await result.current.openChat({ id: SENDER.user_id, type: 'friend', group_id: '' }); });
  return result;
}

describe('useMessaging WS onmessage — phantom empty bubble regression', () => {
  test('a {"type":"ping"} heartbeat frame while a DM thread is open never adds an entry to messages', async () => {
    const result = await connectedToDM();
    const ws = MockWebSocket.instances[0];

    act(() => { ws.onmessage({ data: JSON.stringify({ type: 'ping' }) }); });

    expect(result.current.messages).toHaveLength(0);
  });

  test('a {"type":"error",...} frame never renders as a blank received bubble, and is surfaced as a toast instead of silently swallowed', async () => {
    const result = await connectedToDM();
    const ws = MockWebSocket.instances[0];

    act(() => {
      ws.onmessage({ data: JSON.stringify({ type: 'error', reason: 'message_rejected', detail: 'That message could not be sent.' }) });
    });

    expect(result.current.messages).toHaveLength(0);
    expect(message.error).toHaveBeenCalled();
  });

  test('a legitimate inbound chat frame (no type key, real from_user/text/timestamp) still renders exactly as before', async () => {
    const result = await connectedToDM();
    const ws = MockWebSocket.instances[0];

    act(() => {
      ws.onmessage({ data: JSON.stringify({
        text: 'hello there', from_user: SENDER.user_id, group_id: '', timestamp: 1,
      }) });
    });

    expect(result.current.messages).toHaveLength(1);
    expect(result.current.messages[0].text).toBe('hello there');
    expect(result.current.messages[0].mine).toBe(false);
  });

  test('a recognized SESSION_TYPES frame still routes through the session-signal callback, not messages', async () => {
    const result = await connectedToDM();
    const ws = MockWebSocket.instances[0];
    const onSignal = vi.fn();
    act(() => { result.current.setOnSessionSignal(onSignal); });

    act(() => { ws.onmessage({ data: JSON.stringify({ type: 'offer', sdp: 'x' }) }); });

    expect(onSignal).toHaveBeenCalledWith(expect.objectContaining({ type: 'offer' }));
    expect(result.current.messages).toHaveLength(0);
  });
});
