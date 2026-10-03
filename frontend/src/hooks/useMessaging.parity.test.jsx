// Task 20261003-web-reader-ios-parity step 3/4: failed-send bubble + retry,
// terms gate draft restore on the main composer, send while offline, and
// addGroupMembers. Run: npx vitest run src/hooks/useMessaging.parity.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { message } from 'antd';
import { useMessaging } from './useMessaging.js';
import { CapabilitiesContext } from '../context/CapabilitiesContext.jsx';

const USER = { user_id: 'u1', username: 'tester' };
const GROUP = { id: 'g1', name: 'G', type: 'group', group_id: 'g1', toUsers: ['u1', 'u2'] };

class MockWebSocket {
  static instances = [];
  constructor(url) { this.url = url; this.readyState = 1; this.sent = []; MockWebSocket.instances.push(this); }
  close() { this.readyState = 3; }
  send(d) { this.sent.push(d); }
}
const ok = (body) => ({ ok: true, status: 200, json: async () => body });
const fail = (status, body = {}) => ({ ok: false, status, json: async () => body });
let refresh; let routes;
const wrapper = ({ children }) => (
  <CapabilitiesContext.Provider value={{ features: {}, isEnabled: () => false, refresh }}>{children}</CapabilitiesContext.Provider>
);
beforeEach(() => {
  MockWebSocket.instances = [];
  global.WebSocket = MockWebSocket;
  refresh = vi.fn();
  routes = [];
  global.fetch = vi.fn(async (url, opts) => {
    for (const [pred, fn] of routes) if (pred(String(url), opts)) return fn(String(url), opts);
    return fail(404);
  });
  vi.spyOn(message, 'error').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => vi.restoreAllMocks());

const ws = () => MockWebSocket.instances[0];
const frame = (data) => act(() => { ws().onmessage({ data: JSON.stringify(data) }); });

async function openGroup() {
  routes.push([(u) => /\/groups\/u1\/g1(\?|$)/.test(u), () => ok({ group: { title: 'G', users: ['u1', 'u2'] }, host_msgs: [], other_msgs: [] })]);
  routes.push([(u) => /\/user\/u2$/.test(u), () => ok({ username: 'two' })]);
  const r = renderHook(() => useMessaging({ user: USER }), { wrapper });
  act(() => { r.result.current.connectWS(); });
  await act(async () => { await r.result.current.openChat(GROUP); });
  return r.result;
}

describe('failed main-chat send', () => {
  test('a rejected send marks the bubble failed (not delivered) and keeps a retry payload', async () => {
    const r = await openGroup();
    act(() => { r.current.sendMessage('hello'); });
    expect(r.current.messages.at(-1)).toMatchObject({ text: 'hello', mine: true });
    frame({ type: 'error', reason: 'blocked', detail: 'Nope' });
    expect(r.current.messages.at(-1)).toMatchObject({ text: 'hello', failed: true, pending: false });
  });

  test('retry removes the failed bubble and sends the same text again', async () => {
    const r = await openGroup();
    act(() => { r.current.sendMessage('hello'); });
    frame({ type: 'error', reason: 'x' });
    const failed = r.current.messages.at(-1);
    act(() => { r.current.retryFailedMessage(failed); });
    expect(r.current.messages.filter((m) => m.failed)).toHaveLength(0);
    expect(r.current.messages.at(-1)).toMatchObject({ text: 'hello', mine: true });
    expect(ws().sent).toHaveLength(2);
    expect(JSON.parse(ws().sent[1]).text).toBe('hello');
  });

  test('retry resends the attachment payload too', async () => {
    const r = await openGroup();
    const att = { kind: 'file', meta: { filename: 'a.pdf' }, objectKey: 'k1', localUrl: null };
    act(() => { r.current.sendMessage('', att); });
    frame({ type: 'error', reason: 'x' });
    act(() => { r.current.retryFailedMessage(r.current.messages.at(-1)); });
    expect(JSON.parse(ws().sent[1])).toMatchObject({ attachment_kind: 'file', attachment_key: 'k1' });
  });

  test('terms_reaccept_required: text-only message is removed and its text goes back to the composer', async () => {
    const r = await openGroup();
    act(() => { r.current.sendMessage('keep me'); });
    frame({ type: 'error', reason: 'terms_reaccept_required' });
    expect(refresh).toHaveBeenCalled();
    expect(r.current.messages.some((m) => m.text === 'keep me')).toBe(false);
    expect(r.current.restoredDraft).toMatchObject({ text: 'keep me' });
  });

  test('an old unacked message is never marked failed by a later unrelated error frame', async () => {
    const r = await openGroup();
    vi.spyOn(Date, 'now').mockReturnValue(Date.parse('2030-01-01T00:00:00Z'));
    act(() => { r.current.sendMessage('long ago'); });
    Date.now.mockReturnValue(Date.parse('2030-01-01T00:05:00Z'));
    frame({ type: 'error', reason: 'x' });
    expect(r.current.messages.some((m) => m.failed)).toBe(false);
  });

  test('an error while a thread is open does not touch the main chat', async () => {
    const r = await openGroup();
    act(() => { r.current.sendMessage('main msg'); });
    act(() => { r.current.openThread({ id: 't1', title: 'T', root_message_id: 'r1', root_deleted: false }); });
    frame({ type: 'error', reason: 'x' });
    expect(r.current.messages.some((m) => m.failed)).toBe(false);
  });

  test('sending while the socket is not open shows a failed bubble instead of dropping the text', async () => {
    const r = await openGroup();
    ws().readyState = 3;
    act(() => { r.current.sendMessage('offline text'); });
    expect(ws().sent).toHaveLength(0);
    expect(r.current.messages.at(-1)).toMatchObject({ text: 'offline text', failed: true });
    ws().readyState = 1;
    act(() => { r.current.retryFailedMessage(r.current.messages.at(-1)); });
    expect(JSON.parse(ws().sent[0]).text).toBe('offline text');
  });
});

describe('addGroupMembers', () => {
  const added = [{ user_id: 'u3', username: 'three', photoUrl: null }];
  test('success PUTs the full member list, then updates contact, members and group list', async () => {
    const r = await openGroup();
    routes.unshift([(u, o) => /\/groups\/u1\/g1$/.test(u) && o?.method === 'PUT', () => ok({})]);
    let res;
    await act(async () => { res = await r.current.addGroupMembers('g1', added); });
    expect(res).toEqual({ ok: true });
    const put = global.fetch.mock.calls.find(([, o]) => o?.method === 'PUT');
    expect(JSON.parse(put[1].body)).toMatchObject({ group_id: 'g1', title: 'G', users: ['u1', 'u2', 'u3'] });
    expect(r.current.currentContact.toUsers).toEqual(['u1', 'u2', 'u3']);
    expect(r.current.groupMembers.some((m) => m.user_id === 'u3')).toBe(true);
  });
  test('a 409 shows the server message and changes nothing locally', async () => {
    const r = await openGroup();
    routes.unshift([(u, o) => /\/groups\/u1\/g1$/.test(u) && o?.method === 'PUT',
      () => fail(409, { detail: { code: 'group_full', message: 'This group is full.' } })]);
    let res;
    await act(async () => { res = await r.current.addGroupMembers('g1', added); });
    expect(res).toMatchObject({ ok: false, status: 409, detail: 'This group is full.' });
    expect(r.current.currentContact.toUsers).toEqual(['u1', 'u2']);
    expect(r.current.groupMembers.some((m) => m.user_id === 'u3')).toBe(false);
  });
  test('network failure and empty selection fail without side effects', async () => {
    const r = await openGroup();
    routes.unshift([(u, o) => o?.method === 'PUT', () => { throw new Error('down'); }]);
    let res;
    await act(async () => { res = await r.current.addGroupMembers('g1', added); });
    expect(res.ok).toBe(false);
    await act(async () => { res = await r.current.addGroupMembers('g1', []); });
    expect(res.ok).toBe(false);
  });
});
