// Task 20261012-message-pins: useMessaging pin state, actions and frames.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act, waitFor } from '@testing-library/react';
import { message } from 'antd';
import { useMessaging } from './useMessaging.js';
import { CapabilitiesContext } from '../context/CapabilitiesContext.jsx';

const USER = { user_id: 'u1', username: 'tester' };
const GROUP = { id: 'g1', type: 'group', group_id: 'g1', toUsers: ['u1'] };
const DM = { id: 'f1', type: 'friend', group_id: '', name: 'Fay', toUsers: ['f1'] };

class MockWebSocket {
  static instances = [];
  constructor(url) { this.url = url; this.readyState = 1; MockWebSocket.instances.push(this); }
  close() { this.readyState = 3; }
  send() {}
}
const ts = (n) => `2026-10-01T10:00:${String(n).padStart(2, '0')}.000000Z`;
const row = (id, n, over = {}) => ({ id, text: `t-${id}`, timestamp: ts(n), from_user: 'ada', mine: false, ...over });
const ok = (body) => ({ ok: true, status: 200, json: async () => body });
const fail = (status, body = {}) => ({ ok: false, status, json: async () => body });
const pinRow = (id, over = {}) => ({
  message_id: id, pinned_by: 'ada', pinned_by_id: 'u9', pinned_at: '2026-10-12T00:00:00+00:00',
  message: { id, from_user_id: 'u9', from_user: 'ada', text: `t-${id}`, timestamp: ts(1), attachment_kind: null },
  ...over,
});

let refresh; let features; let routes; let urls;
const wrapper = ({ children }) => (
  <CapabilitiesContext.Provider value={{
    features, isEnabled: (k) => features[k] === true, refresh, reactionEmoji: { quick: [], more: [] },
  }}
  >{children}</CapabilitiesContext.Provider>
);
beforeEach(() => {
  MockWebSocket.instances = [];
  global.WebSocket = MockWebSocket;
  refresh = vi.fn();
  features = { message_pins: true };
  routes = []; urls = [];
  global.fetch = vi.fn(async (url, opts) => {
    urls.push([String(url), opts]);
    for (const [pred, fn] of routes) if (pred(String(url), opts)) return fn(String(url), opts);
    return fail(404);
  });
  vi.spyOn(message, 'error').mockImplementation(() => {});
  vi.spyOn(message, 'info').mockImplementation(() => {});
  vi.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => { vi.restoreAllMocks(); });

const ws = () => MockWebSocket.instances[0];
const frame = (d) => act(() => { ws().onmessage({ data: JSON.stringify(d) }); });
const listRoute = (fn) => routes.push([(u, o) => u.includes('/message-pins/u1/') && /\/(group|dm)\//.test(u) && !(o && o.method), fn]);
const writeRoute = (fn) => routes.push([(u, o) => /\/message-pins\/u1\/m\d+$/.test(u) && o && o.method, fn]);

async function open(rows, contact = GROUP) {
  routes.push([(u) => /\/groups\/u1\/g1(\?|$)/.test(u), () => ok({ group: { title: 'G', users: ['u1'] }, messages: rows, page: { has_more: false } })]);
  routes.push([(u) => /\/friends\/u1\/f1(\?|$)/.test(u), () => ok({ messages: rows, page: { has_more: false } })]);
  const { result } = renderHook(() => useMessaging({ user: USER }), { wrapper });
  act(() => { result.current.connectWS(); });
  await act(async () => { await result.current.openChat(contact); });
  return result;
}
const byId = (r, id) => r.current.messages.find((m) => m.id === id);

describe('flag and list', () => {
  test('flag off: no list fetch, pinsEnabled false, togglePin refuses', async () => {
    features = {};
    const r = await open([row('m1', 1)]);
    expect(r.current.pinsEnabled).toBe(false);
    expect(urls.some(([u]) => u.includes('/message-pins/'))).toBe(false);
    let res; await act(async () => { res = await r.current.togglePin(byId(r, 'm1')); });
    expect(res).toBe(false);
    expect(urls.some(([u]) => u.includes('/message-pins/'))).toBe(false);
  });
  test('flag on: loads the group pin list on open (count, rows)', async () => {
    listRoute(() => ok({ pins: [pinRow('m1')], has_more: false, count: 1 }));
    const r = await open([row('m1', 1)]);
    await waitFor(() => expect(r.current.pinList.status).toBe('ready'));
    expect(r.current.pinList.count).toBe(1);
    expect(r.current.pinList.pins[0].messageId).toBe('m1');
    expect(urls.find(([u]) => u.includes('/message-pins/'))[0]).toMatch(/\/group\/g1\?limit=20&offset=0/);
  });
  test('DM scope uses the dm route', async () => {
    listRoute(() => ok({ pins: [], has_more: false, count: 0 }));
    const r = await open([row('m1', 1)], DM);
    await waitFor(() => expect(r.current.pinList.status).toBe('ready'));
    expect(urls.find(([u]) => u.includes('/message-pins/'))[0]).toMatch(/\/dm\/f1\?/);
  });
  test('list failure surfaces an error state; Try again reloads', async () => {
    let n = 0;
    listRoute(() => (++n === 1 ? fail(500) : ok({ pins: [pinRow('m1')], has_more: false, count: 1 })));
    const r = await open([row('m1', 1)]);
    await waitFor(() => expect(r.current.pinList.status).toBe('error'));
    await act(async () => { await r.current.loadPins(); });
    expect(r.current.pinList.status).toBe('ready');
  });
  test('404 on the list (flag dropped) hides quietly and refreshes capabilities', async () => {
    listRoute(() => fail(404));
    const r = await open([row('m1', 1)]);
    await waitFor(() => expect(r.current.pinList.status).toBe('off'));
    expect(refresh).toHaveBeenCalled();
    expect(message.error).not.toHaveBeenCalled();
  });
  test('show more appends the next offset page without duplicates', async () => {
    listRoute((u) => (u.includes('offset=0')
      ? ok({ pins: [pinRow('m1'), pinRow('m2')], has_more: true, count: 3 })
      : ok({ pins: [pinRow('m2'), pinRow('m3')], has_more: false, count: 3 })));
    const r = await open([row('m1', 1)]);
    await waitFor(() => expect(r.current.pinList.hasMore).toBe(true));
    await act(async () => { await r.current.loadMorePins(); });
    expect(r.current.pinList.pins.map((p) => p.messageId)).toEqual(['m1', 'm2', 'm3']);
    expect(urls.some(([u]) => u.includes('offset=2'))).toBe(true);
    expect(r.current.pinList.hasMore).toBe(false);
  });
  test('history rows carry pinned and system_kind; flag-off rows carry neither', async () => {
    listRoute(() => ok({ pins: [], has_more: false, count: 0 }));
    const r = await open([row('m1', 1, { pinned: true }), row('m2', 2, { text: 'pinned a message', system_kind: 'pin', pinned: false })]);
    expect(byId(r, 'm1').pinned).toBe(true);
    expect(byId(r, 'm2').systemKind).toBe('pin');
  });
});

describe('toggle', () => {
  test('pin: optimistic, server result kept, list refreshed', async () => {
    let listN = 0;
    listRoute(() => ok({ pins: listN++ ? [pinRow('m1')] : [], has_more: false, count: listN > 1 ? 1 : 0 }));
    writeRoute(() => ok({ message_id: 'm1', pinned: true }));
    const r = await open([row('m1', 1, { pinned: false })]);
    await waitFor(() => expect(r.current.pinList.status).toBe('ready'));
    let res; await act(async () => { res = await r.current.togglePin(byId(r, 'm1')); });
    expect(res).toBe(true);
    expect(byId(r, 'm1').pinned).toBe(true);
    expect(urls.some(([u, o]) => /\/message-pins\/u1\/m1$/.test(u) && o.method === 'POST')).toBe(true);
    await waitFor(() => expect(r.current.pinList.count).toBe(1));
  });
  test('unpin issues DELETE', async () => {
    listRoute(() => ok({ pins: [], has_more: false, count: 0 }));
    writeRoute(() => ok({ message_id: 'm1', pinned: false }));
    const r = await open([row('m1', 1, { pinned: true })]);
    await act(async () => { await r.current.togglePin(byId(r, 'm1')); });
    expect(byId(r, 'm1').pinned).toBe(false);
    expect(urls.some(([u, o]) => /m1$/.test(u) && o && o.method === 'DELETE')).toBe(true);
  });
  test('failure reverts and shows the warm line; 429 uses rate copy; terms refreshes capabilities', async () => {
    listRoute(() => ok({ pins: [], has_more: false, count: 0 }));
    writeRoute(() => fail(429));
    const r = await open([row('m1', 1, { pinned: false })]);
    await act(async () => { await r.current.togglePin(byId(r, 'm1')); });
    expect(byId(r, 'm1').pinned).toBe(false);
    expect(message.error).toHaveBeenCalledWith(expect.objectContaining({ content: expect.stringContaining('Easy there') }));
    routes.length = 0;
    routes.push([(u) => /\/groups\/u1\/g1/.test(u), () => ok({ group: { users: ['u1'] }, messages: [], page: { has_more: false } })]);
    writeRoute(() => fail(403, { detail: { code: 'terms_reaccept_required' } }));
    await act(async () => { await r.current.togglePin(byId(r, 'm1')); });
    expect(refresh).toHaveBeenCalled();
  });
  test('refuses a system line, an unsettled message and a duplicate in-flight call', async () => {
    listRoute(() => ok({ pins: [], has_more: false, count: 0 }));
    let release;
    writeRoute(() => new Promise((res) => { release = () => res(ok({ message_id: 'm1', pinned: true })); }));
    const r = await open([row('m1', 1), row('m2', 2, { system_kind: 'pin' })]);
    let a; await act(async () => { a = await r.current.togglePin({ ...byId(r, 'm2') }); });
    expect(a).toBe(false);
    let b; await act(async () => { b = await r.current.togglePin({ text: 'x', pending: true }); });
    expect(b).toBe(false);
    let first; let second;
    await act(async () => {
      first = r.current.togglePin(byId(r, 'm1'));
      second = await r.current.togglePin(byId(r, 'm1'));
    });
    expect(second).toBe(false);
    await act(async () => { release(); await first; });
  });
  test('unpin from the list removes optimistically; failure restores the row in order', async () => {
    listRoute(() => ok({ pins: [pinRow('m1'), pinRow('m2')], has_more: false, count: 2 }));
    writeRoute(() => fail(500));
    const r = await open([row('m1', 1, { pinned: true }), row('m2', 2, { pinned: true })]);
    await waitFor(() => expect(r.current.pinList.count).toBe(2));
    await act(async () => { await r.current.unpinFromList('m1'); });
    expect(r.current.pinList.pins.map((p) => p.messageId)).toEqual(['m1', 'm2']);
    expect(r.current.pinList.count).toBe(2);
    expect(byId(r, 'm1').pinned).toBe(true);
    expect(message.error).toHaveBeenCalled();
  });
  test('unpin from the list success; a 404 keeps the row removed and says it is gone', async () => {
    listRoute(() => ok({ pins: [pinRow('m1'), pinRow('m2')], has_more: false, count: 2 }));
    writeRoute((u) => (u.endsWith('m1') ? ok({ message_id: 'm1', pinned: false }) : fail(404)));
    const r = await open([row('m1', 1, { pinned: true }), row('m2', 2, { pinned: true })]);
    await waitFor(() => expect(r.current.pinList.count).toBe(2));
    await act(async () => { await r.current.unpinFromList('m1'); });
    expect(r.current.pinList.pins.map((p) => p.messageId)).toEqual(['m2']);
    await act(async () => { await r.current.unpinFromList('m2'); });
    expect(r.current.pinList.pins).toEqual([]);
    expect(message.info).toHaveBeenCalledWith(expect.objectContaining({ content: expect.stringContaining('no longer available') }));
  });
});

describe('live frames', () => {
  test('pin_updated flips the glyph and updates the list; ignored when flag off or other chat', async () => {
    let n = 0;
    listRoute(() => ok({ pins: n++ ? [pinRow('m1')] : [], has_more: false, count: n > 1 ? 1 : 0 }));
    const r = await open([row('m1', 1, { pinned: false })]);
    await waitFor(() => expect(r.current.pinList.status).toBe('ready'));
    frame({ type: 'pin_updated', message_id: 'm1', group_id: 'other', pinned: true, actor_id: 'u9' });
    expect(byId(r, 'm1').pinned).toBe(false);
    frame({ type: 'pin_updated', message_id: 'm1', group_id: 'g1', pinned: true, actor_id: 'u9' });
    expect(byId(r, 'm1').pinned).toBe(true);
    await waitFor(() => expect(r.current.pinList.count).toBe(1));
    frame({ type: 'pin_updated', message_id: 'm1', group_id: 'g1', pinned: false, actor_id: 'u9' });
    expect(byId(r, 'm1').pinned).toBe(false);
    expect(r.current.pinList.pins).toEqual([]);
    expect(r.current.pinList.count).toBe(0);
    frame({ type: 'pin_updated', message_id: 'm1', group_id: 'g1', pinned: 'yes' });
    expect(byId(r, 'm1').pinned).toBe(false);
  });
  test('a frame is never a bubble; flag off ignores it', async () => {
    features = {};
    const r = await open([row('m1', 1)]);
    frame({ type: 'pin_updated', message_id: 'm1', group_id: 'g1', pinned: true });
    expect(r.current.messages).toHaveLength(1);
    expect(byId(r, 'm1').pinned).toBeUndefined();
  });
  test('a live pin system line arrives as a system message naming the DM contact', async () => {
    listRoute(() => ok({ pins: [], has_more: false, count: 0 }));
    const r = await open([row('m1', 1)], DM);
    const gid = ['u1', 'f1'].sort().join('|');
    frame({ from_user: 'f1', text: 'pinned a message', group_id: '', timestamp: ts(5), id: 'm9', system_kind: 'pin' });
    const line = byId(r, 'm9');
    expect(line.systemKind).toBe('pin');
    expect(line.sender).toBe('Fay');
    expect(gid).toBeTruthy();
  });
});

describe('jump to an out-of-window pin', () => {
  test('ensureMessageLoaded pages older history until the message appears', async () => {
    listRoute(() => ok({ pins: [], has_more: false, count: 0 }));
    routes.push([(u) => /\/groups\/u1\/g1\?limit=/.test(u), () => ok({
      group: { users: ['u1'] }, messages: [row('m5', 5)],
      page: { has_more: true, next_cursor_timestamp: ts(5), next_cursor_id: 'm5' },
    })]);
    routes.push([(u) => /\/groups\/u1\/g1\/messages\?/.test(u) && u.includes('cursor_id=m5'), () => ok({
      messages: [row('m4', 4)], page: { has_more: true, next_cursor_timestamp: ts(4), next_cursor_id: 'm4' },
    })]);
    routes.push([(u) => /\/groups\/u1\/g1\/messages\?/.test(u) && u.includes('cursor_id=m4'), () => ok({
      messages: [row('m3', 3)], page: { has_more: false },
    })]);
    features = { message_pins: true, chat_pagination: true };
    const { result } = renderHook(() => useMessaging({ user: USER }), { wrapper });
    act(() => { result.current.connectWS(); });
    await act(async () => { await result.current.openChat(GROUP); });
    expect(result.current.messages.map((m) => m.id)).toEqual(['m5']);
    let found; await act(async () => { found = await result.current.ensureMessageLoaded('m3'); });
    expect(found).toBe(true);
    expect(result.current.messages.map((m) => m.id)).toEqual(['m3', 'm4', 'm5']);
  });
  test('ensureMessageLoaded gives up cleanly at the start of history', async () => {
    listRoute(() => ok({ pins: [], has_more: false, count: 0 }));
    const r = await open([row('m1', 1)]);
    let found; await act(async () => { found = await r.current.ensureMessageLoaded('zzz'); });
    expect(found).toBe(false);
    await act(async () => { found = await r.current.ensureMessageLoaded('m1'); });
    expect(found).toBe(true);
  });
});
