// Task 20261030-profile-everywhere (step 9): useMessaging attaches senderId only
// for a real UUID sender id; the displayed sender name is unchanged.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { message } from 'antd';
import { useMessaging } from './useMessaging.js';
import { CapabilitiesContext } from '../context/CapabilitiesContext.jsx';

const USER = { user_id: 'u1', username: 'tester' };
const GROUP = { id: 'g1', type: 'group', group_id: 'g1', toUsers: ['u1', 'a'] };
class MockWebSocket {
  static instances = [];
  constructor(url) { this.url = url; this.readyState = 1; this.sent = []; MockWebSocket.instances.push(this); }
  close() { this.readyState = 3; }
  send(d) { this.sent.push(d); }
}
const ok = (b) => ({ ok: true, status: 200, json: async () => b });
let features;
const wrapper = ({ children }) => (
  <CapabilitiesContext.Provider value={{ features, isEnabled: (k) => features[k] === true, refresh: vi.fn(), reactionEmoji: { quick: [], more: [] } }}>
    {children}
  </CapabilitiesContext.Provider>
);
beforeEach(() => {
  MockWebSocket.instances = [];
  global.WebSocket = MockWebSocket;
  features = { chat_mentions: true };
  global.fetch = vi.fn(async (url) => (/\/groups\/u1\/g1(\?|$)/.test(String(url))
    ? ok({ group: { title: 'G', users: ['u1'] }, host_msgs: [], other_msgs: [] })
    : { ok: false, status: 404, json: async () => ({}) }));
  vi.spyOn(message, 'error').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => { vi.restoreAllMocks(); });

const ws = () => MockWebSocket.instances[0];
async function open() {
  const { result } = renderHook(() => useMessaging({ user: USER }), { wrapper });
  act(() => { result.current.connectWS(); });
  await act(async () => { await result.current.openChat(GROUP); });
  return result;
}
const UID = '123e4567-e89b-42d3-a456-426614174000';
const frame = (r, d) => act(() => { ws().onmessage({ data: JSON.stringify(d) }); });
const by = (r, id) => r.current.messages.find(m => m.id === id);

describe('senderId on live frames', () => {
  test('UUID from_user sets senderId; name-like from_user does not; sender label unchanged', async () => {
    const r = await open();
    const base = { group_id: 'g1', timestamp: '2026-10-30T10:00:00Z' };
    frame(r, { ...base, id: 'a1', from_user: UID, text: 'x' });
    frame(r, { ...base, id: 'a2', from_user: 'ada', text: 'y' });
    expect(by(r, 'a1').senderId).toBe(UID);
    expect('senderId' in by(r, 'a2')).toBe(false);
    expect(by(r, 'a2').sender).toBe('ada');
  });
  test('malformed id (path-like) never becomes senderId', async () => {
    const r = await open();
    frame(r, { group_id: 'g1', timestamp: '2026-10-30T10:00:00Z', id: 'b1', from_user: `${UID}/../x`, text: 'z' });
    expect('senderId' in by(r, 'b1')).toBe(false);
  });
});
