// Task 20261017-chat-mentions: useMessaging wire in/out for the mentions field.
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
const MENTION = [{ userId: 'a', username: 'Ada', start: 3, length: 4 }];
const sent = () => JSON.parse(ws().sent[ws().sent.length - 1]);

describe('outgoing', () => {
  test('flag on: payload carries exactly {user_id,start,length}; optimistic copy keeps usernames', async () => {
    const r = await open();
    act(() => { r.current.sendMessage('hi @Ada', null, null, MENTION); });
    expect(sent().mentions).toEqual([{ user_id: 'a', start: 3, length: 4 }]);
    expect(sent().text).toBe('hi @Ada');
    expect(r.current.messages.at(-1).mentions).toEqual(MENTION);
  });
  test('flag off: no mentions key', async () => {
    features = {};
    const r = await open();
    act(() => { r.current.sendMessage('hi @Ada', null, null, MENTION); });
    expect('mentions' in sent()).toBe(false);
    expect('mentions' in r.current.messages.at(-1)).toBe(false);
  });
  test('a stale range is never sent', async () => {
    const r = await open();
    act(() => { r.current.sendMessage('hi @Adx', null, null, MENTION); });
    expect('mentions' in sent()).toBe(false);
  });
  test('a plain send has no mentions key', async () => {
    const r = await open();
    act(() => { r.current.sendMessage('hello'); });
    expect('mentions' in sent()).toBe(false);
  });
});

describe('incoming', () => {
  test('live frame with mentions renders ranges; one without has no key; bad ranges dropped', async () => {
    const r = await open();
    const frame = (d) => act(() => { ws().onmessage({ data: JSON.stringify(d) }); });
    const base = { from_user: 'ada', group_id: 'g1', timestamp: '2026-10-17T10:00:00Z' };
    frame({ ...base, id: 'm1', text: 'yo @Tester', mentions: [{ user_id: 'U1', start: 3, length: 7, username: 'Tester' }] });
    frame({ ...base, id: 'm2', text: 'plain' });
    frame({ ...base, id: 'm3', text: 'bad', mentions: [{ user_id: 'u1', start: 9, length: 7 }] });
    const by = (id) => r.current.messages.find(m => m.id === id);
    expect(by('m1').mentions).toEqual([{ userId: 'u1', start: 3, length: 7, username: 'Tester' }]);
    expect('mentions' in by('m2')).toBe(false);
    expect('mentions' in by('m3')).toBe(false);
  });
});
