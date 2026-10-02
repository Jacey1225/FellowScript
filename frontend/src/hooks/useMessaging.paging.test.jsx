// Task 20261001-chat-pagination step 8: useMessaging paging behaviour, gated by
// the SF capabilities hook (chat_pagination / chat_pagination_dm).
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { message } from 'antd';
import { useMessaging } from './useMessaging.js';
import { CapabilitiesContext } from '../context/CapabilitiesContext.jsx';

const USER = { user_id: 'u1', username: 'tester' };
const GROUP = { id: 'g1', type: 'group', group_id: 'g1', toUsers: ['u1'] };
const FRIEND = { id: 'f1', type: 'friend', group_id: '', toUsers: ['f1'] };

class MockWebSocket {
  static instances = [];
  constructor(url) { this.url = url; this.readyState = 1; this.sent = []; MockWebSocket.instances.push(this); }
  close() { this.readyState = 3; }
  send(d) { this.sent.push(d); }
}

const ts = (n) => `2026-10-01T10:00:${String(n).padStart(2, '0')}.000000Z`;
const row = (id, n, over = {}) => ({ id, text: `t-${id}`, timestamp: ts(n), from_user: 'ada', mine: false, ...over });
const page = (rows, more, cur = {}) => ({
  group: { title: 'G', users: ['u1'] },
  messages: rows,
  page: more ? { has_more: true, next_cursor_timestamp: ts(0), next_cursor_seq: 3, next_cursor_id: rows[0]?.id || 'x', ...cur } : { has_more: false },
});
const ok = (body) => ({ ok: true, status: 200, json: async () => body });

const wrapperFor = (flags) => ({ children }) => (
  <CapabilitiesContext.Provider value={{ features: flags, isEnabled: (n) => flags[n] === true }}>{children}</CapabilitiesContext.Provider>
);

let urls;
let routes; // array of [predicate, responder]
function installFetch() {
  urls = [];
  global.fetch = vi.fn(async (url) => {
    urls.push(String(url));
    for (const [pred, fn] of routes) if (pred(String(url))) return fn(String(url));
    return { ok: false, status: 404, json: async () => ({}) };
  });
}

beforeEach(() => {
  MockWebSocket.instances = [];
  global.WebSocket = MockWebSocket;
  routes = [];
  installFetch();
  vi.spyOn(message, 'error').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });

const setup = (flags) => renderHook(() => useMessaging({ user: USER }), { wrapper: wrapperFor(flags) }).result;
const ws = () => MockWebSocket.instances[0];
const ids = (r) => r.current.messages.map(m => m.id);

describe('capability gating', () => {
  test('flag off: legacy full-history fetch, no limit, no client_ref', async () => {
    routes.push([u => u.includes('/groups/u1/g1'), () => ok({ group: {}, host_msgs: [{ id: 'h', text: 'a', timestamp: ts(1) }], other_msgs: [{ id: 'o', text: 'b', timestamp: ts(2), from_user: 'ada' }] })]);
    const r = setup({});
    act(() => { r.current.connectWS(); });
    await act(async () => { await r.current.openChat(GROUP); });
    expect(urls[0]).toBe('http://localhost:8000/groups/u1/g1'.replace('http://localhost:8000', urls[0].replace(/\/groups.*/, '')));
    expect(urls[0]).not.toContain('limit');
    expect(r.current.olderPage.paged).toBe(false);
    expect(ids(r)).toEqual(['h', 'o']);
    act(() => { r.current.sendMessage('hello'); });
    expect(JSON.parse(ws().sent[0]).client_ref).toBeUndefined();
    expect(r.current.messages[2].pending).toBeUndefined();
  });

  test('group flag on, DM flag off: group paged, DM legacy', async () => {
    routes.push([u => u.includes('/groups/u1/g1'), () => ok(page([row('a', 1)], false))]);
    routes.push([u => u.includes('/friends/u1/f1'), () => ok({ host_msgs: [], other_msgs: [] })]);
    const r = setup({ chat_pagination: true });
    await act(async () => { await r.current.openChat(GROUP); });
    expect(urls[0]).toContain('?limit=30');
    expect(r.current.olderPage.paged).toBe(true);
    await act(async () => { await r.current.openChat(FRIEND); });
    expect(urls.find(u => u.includes('/friends/u1/f1'))).not.toContain('limit');
    expect(r.current.olderPage.paged).toBe(false);
  });

  test('DM flag on pages DMs only', async () => {
    routes.push([u => u.includes('/friends/u1/f1'), () => ok(page([row('a', 1)], false))]);
    const r = setup({ chat_pagination_dm: true });
    await act(async () => { await r.current.openChat(FRIEND); });
    expect(urls[0]).toContain('/friends/u1/f1?limit=30');
    expect(r.current.olderPage.paged).toBe(true);
  });

  test('flag on but server returns legacy shape: falls back, not paged', async () => {
    routes.push([u => u.includes('/groups/u1/g1'), () => ok({ host_msgs: [{ id: 'h', text: 'a', timestamp: ts(1) }], other_msgs: [] })]);
    const r = setup({ chat_pagination: true });
    await act(async () => { await r.current.openChat(GROUP); });
    expect(r.current.olderPage.paged).toBe(false);
    expect(ids(r)).toEqual(['h']);
    await act(async () => { await r.current.loadOlder(); });
    expect(urls).toHaveLength(1);
  });
});

describe('paging', () => {
  test('first page keeps server order; loadOlder prepends with cursor, dedups, ends', async () => {
    routes.push([u => u.includes('/groups/u1/g1/messages'), () => ok(page([row('a', 1), row('b', 2), row('c', 3)], false))]);
    routes.push([u => u.includes('/groups/u1/g1'), () => ok(page([row('c', 3), row('d', 4)], true, { next_cursor_id: 'c' }))]);
    const r = setup({ chat_pagination: true });
    await act(async () => { await r.current.openChat(GROUP); });
    expect(ids(r)).toEqual(['c', 'd']);
    expect(r.current.olderPage.hasMore).toBe(true);
    await act(async () => { await r.current.loadOlder(); });
    const u = urls.find(x => x.includes('/messages?'));
    expect(u).toContain('/groups/u1/g1/messages?limit=30');
    expect(u).toContain('cursor_id=c');
    expect(u).toContain('cursor_seq=3');
    expect(ids(r)).toEqual(['a', 'b', 'c', 'd']);
    expect(r.current.olderPage).toMatchObject({ hasMore: false, loading: false, error: false, loadedCount: 3, loadedTick: 1 });
    await act(async () => { await r.current.loadOlder(); });
    expect(urls.filter(x => x.includes('/messages?'))).toHaveLength(1);
  });

  test('DM older page uses the friends route', async () => {
    routes.push([u => u.includes('/friends/u1/f1/messages'), () => ok(page([row('a', 1)], false))]);
    routes.push([u => u.includes('/friends/u1/f1'), () => ok(page([row('b', 2)], true, { next_cursor_id: 'b' }))]);
    const r = setup({ chat_pagination_dm: true });
    await act(async () => { await r.current.openChat(FRIEND); });
    await act(async () => { await r.current.loadOlder(); });
    expect(urls.some(u => u.includes('/friends/u1/f1/messages?'))).toBe(true);
    expect(ids(r)).toEqual(['a', 'b']);
  });

  test('concurrent loadOlder calls issue one request', async () => {
    let release;
    routes.push([u => u.includes('/messages?'), () => new Promise(res => { release = () => res(ok(page([row('a', 1)], false))); })]);
    routes.push([u => u.includes('/groups/u1/g1'), () => ok(page([row('b', 2)], true, { next_cursor_id: 'b' }))]);
    const r = setup({ chat_pagination: true });
    await act(async () => { await r.current.openChat(GROUP); });
    let p1, p2;
    await act(async () => { p1 = r.current.loadOlder(); p2 = r.current.loadOlder(); });
    expect(urls.filter(u => u.includes('/messages?'))).toHaveLength(1);
    expect(r.current.olderPage.loading).toBe(true);
    await act(async () => { release(); await p1; await p2; });
    expect(ids(r)).toEqual(['a', 'b']);
  });

  test('failure sets error and the same call retries', async () => {
    let fail = true;
    routes.push([u => u.includes('/messages?'), () => (fail ? { ok: false, status: 500, json: async () => ({}) } : ok(page([row('a', 1)], false)))]);
    routes.push([u => u.includes('/groups/u1/g1'), () => ok(page([row('b', 2)], true, { next_cursor_id: 'b' }))]);
    const r = setup({ chat_pagination: true });
    await act(async () => { await r.current.openChat(GROUP); });
    await act(async () => { await r.current.loadOlder(); });
    expect(r.current.olderPage).toMatchObject({ error: true, loading: false, hasMore: true });
    expect(ids(r)).toEqual(['b']);
    fail = false;
    await act(async () => { await r.current.loadOlder(); });
    expect(r.current.olderPage.error).toBe(false);
    expect(ids(r)).toEqual(['a', 'b']);
  });

  test('a response for a closed thread is dropped (stale token)', async () => {
    let release;
    routes.push([u => u.includes('/messages?'), () => new Promise(res => { release = () => res(ok(page([row('old', 1)], false))); })]);
    routes.push([u => u.includes('/groups/u1/g1'), () => ok(page([row('b', 2)], true, { next_cursor_id: 'b' }))]);
    const r = setup({ chat_pagination: true });
    await act(async () => { await r.current.openChat(GROUP); });
    let p;
    await act(async () => { p = r.current.loadOlder(); });
    act(() => { r.current.closeChat(); });
    await act(async () => { release(); await p; });
    expect(r.current.messages).toEqual([]);
    expect(r.current.olderPage.paged).toBe(false);
  });
});

describe('live frames and acks', () => {
  async function paged() {
    routes.push([u => u.includes('/groups/u1/g1'), () => ok(page([row('a', 1)], false))]);
    const r = setup({ chat_pagination: true });
    act(() => { r.current.connectWS(); });
    await act(async () => { await r.current.openChat(GROUP); });
    return r;
  }
  const frame = (o) => ({ data: JSON.stringify({ from_user: 'ada', group_id: 'g1', text: 'x', timestamp: ts(9), ...o }) });

  test('live frame with an id already loaded is deduped; new id appended', async () => {
    const r = await paged();
    act(() => { ws().onmessage(frame({ id: 'a' })); });
    expect(ids(r)).toEqual(['a']);
    act(() => { ws().onmessage(frame({ id: 'n1' })); });
    expect(ids(r)).toEqual(['a', 'n1']);
  });

  test('send includes client_ref; ack replaces the bubble in place and never adds one', async () => {
    const r = await paged();
    act(() => { r.current.sendMessage('hello'); });
    const sent = JSON.parse(ws().sent[0]);
    expect(sent.client_ref).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(r.current.messages[1]).toMatchObject({ pending: true, mine: true });
    act(() => { ws().onmessage({ data: JSON.stringify({ type: 'ack', client_ref: sent.client_ref, id: 'm9', group_id: 'g1', timestamp: ts(30) }) }); });
    expect(r.current.messages).toHaveLength(2);
    expect(r.current.messages[1]).toMatchObject({ id: 'm9', pending: false, text: 'hello' });
  });

  test('error frame is never an ack and leaves the pending bubble', async () => {
    const r = await paged();
    act(() => { r.current.sendMessage('hello'); });
    const ref = JSON.parse(ws().sent[0]).client_ref;
    act(() => { ws().onmessage({ data: JSON.stringify({ type: 'error', client_ref: ref, id: 'm9', reason: 'x', detail: 'no' }) }); });
    expect(r.current.messages).toHaveLength(2);
    expect(r.current.messages[1].pending).toBe(true);
    expect(message.error).toHaveBeenCalled();
  });

  test('ack with unknown client_ref changes nothing', async () => {
    const r = await paged();
    act(() => { ws().onmessage({ data: JSON.stringify({ type: 'ack', client_ref: 'zzz', id: 'q' }) }); });
    expect(ids(r)).toEqual(['a']);
  });

  test('lost ack: after 5 s refetch newest page, match once, no second fetch', async () => {
    const r = await paged();
    vi.useFakeTimers();
    act(() => { r.current.sendMessage('hello'); });
    const sentTs = JSON.parse(ws().sent[0]).timestamp;
    routes.unshift([u => u.includes('/groups/u1/g1/messages'), () => ok(page([row('a', 1), row('mm', 2, { mine: true, text: 'hello', timestamp: sentTs })], false))]);
    await act(async () => { await vi.advanceTimersByTimeAsync(4900); });
    expect(urls.some(u => u.includes('/messages?'))).toBe(false);
    await act(async () => { await vi.advanceTimersByTimeAsync(200); });
    expect(urls.filter(u => u.includes('/messages?'))).toHaveLength(1);
    expect(r.current.messages).toHaveLength(2);
    expect(r.current.messages[1]).toMatchObject({ id: 'mm', pending: false });
    await act(async () => { await vi.advanceTimersByTimeAsync(20000); });
    expect(urls.filter(u => u.includes('/messages?'))).toHaveLength(1);
  });

  test('lost ack with no match keeps the bubble', async () => {
    const r = await paged();
    vi.useFakeTimers();
    act(() => { r.current.sendMessage('hello'); });
    routes.unshift([u => u.includes('/groups/u1/g1/messages'), () => ok(page([row('a', 1)], false))]);
    await act(async () => { await vi.advanceTimersByTimeAsync(5100); });
    expect(r.current.messages).toHaveLength(2);
    expect(r.current.messages[1].pending).toBe(true);
  });

  test('ack arriving before 5 s cancels the fallback', async () => {
    const r = await paged();
    vi.useFakeTimers();
    act(() => { r.current.sendMessage('hello'); });
    const ref = JSON.parse(ws().sent[0]).client_ref;
    act(() => { ws().onmessage({ data: JSON.stringify({ type: 'ack', client_ref: ref, id: 'm9', timestamp: ts(5) }) }); });
    await act(async () => { await vi.advanceTimersByTimeAsync(6000); });
    expect(urls.some(u => u.includes('/messages?'))).toBe(false);
  });
});

describe('previews', () => {
  const userDoc = { user_id: 'u1', username: 'tester', friends: ['f1'], groups: ['g1'] };
  function loadRoutes(opts = {}) {
    routes.push([u => u.endsWith('/user/u1'), () => ok(userDoc)]);
    routes.push([u => u.includes('/user/f1'), () => ok({ username: 'fred' })]);
    routes.push([u => u.includes('/message/messages/u1/'), () => ok({ payload: opts.dm })]);
    routes.push([u => u.includes('/groups/u1/g1'), () => ok(opts.group)]);
  }
  test('flags on: limit=1 for group and DM, preview is the last row', async () => {
    loadRoutes({ dm: page([row('d1', 1, { text: 'dm-last' })], false), group: page([row('g9', 1, { text: 'grp-last' })], false) });
    const r = setup({ chat_pagination: true, chat_pagination_dm: true });
    let out;
    await act(async () => { out = await r.current.loadContacts(); });
    expect(urls.find(u => u.includes('/message/messages/u1/'))).toContain('limit=1');
    expect(urls.find(u => /\/groups\/u1\/g1/.test(u))).toContain('?limit=1');
    expect(out.friends[0].preview).toBe('dm-last');
    expect(out.groups[0].preview).toBe('grp-last');
  });
  test('flags off: no limit param and legacy shape previews still work', async () => {
    loadRoutes({
      dm: { host_msgs: [{ text: 'old', timestamp: '2026-01-01T00:00:00Z' }], other_msgs: [{ text: 'new', timestamp: '2026-02-01T00:00:00Z' }] },
      group: { group: { title: 'G', users: [] }, host_msgs: [], other_msgs: [{ text: 'gl', timestamp: ts(1), from_user: 'a' }] },
    });
    const r = setup({});
    let out;
    await act(async () => { out = await r.current.loadContacts(); });
    expect(urls.filter(u => u.includes('limit'))).toEqual([]);
    expect(out.friends[0].preview).toBe('new');
    expect(out.groups[0].preview).toBe('gl');
  });
});
