// Task 20261001-message-threads step 9: useMessaging thread paging, frames,
// delete/undo, error handling and the terms gate refresh.
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
const pageBody = (rows, more) => ({
  messages: rows,
  page: more ? { has_more: true, next_cursor_timestamp: ts(0), next_cursor_seq: 3, next_cursor_id: rows[0]?.id || 'x' } : { has_more: false },
});
const ok = (body) => ({ ok: true, status: 200, json: async () => body });
const fail = (status, body = {}) => ({ ok: false, status, json: async () => body });

let refresh;
const wrapper = ({ children }) => (
  <CapabilitiesContext.Provider value={{ features: { threads: true, message_delete: true }, isEnabled: () => true, refresh }}>{children}</CapabilitiesContext.Provider>
);
let urls; let routes;
beforeEach(() => {
  MockWebSocket.instances = [];
  global.WebSocket = MockWebSocket;
  refresh = vi.fn();
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

const THREAD = { id: 't1', title: 'Topic', root_message_id: 'r1', root_deleted: false };
const ws = () => MockWebSocket.instances[0];
const frame = (data) => act(() => { ws().onmessage({ data: JSON.stringify(data) }); });

async function openGroup(groupRows = [row('r1', 1), row('m2', 2, { mine: true })]) {
  routes.push([(u) => /\/groups\/u1\/g1(\?|$)/.test(u), () => ok({ group: { title: 'G', users: ['u1'] }, ...pageBody(groupRows, false) })]);
  const { result } = renderHook(() => useMessaging({ user: USER }), { wrapper });
  act(() => { result.current.connectWS(); });
  await act(async () => { await result.current.openChat(GROUP); });
  return result;
}

describe('thread open + paging via chatPaging', () => {
  test('openThread loads the first page, then loadOlderThread prepends with the cursor and dedups', async () => {
    const r = await openGroup();
    routes.push([(u) => u.includes('/threads/t1/messages?') && u.includes('cursor_id'), () => ok(pageBody([row('a', 1), row('b', 2)], false))]);
    routes.push([(u) => u.includes('/threads/t1/messages?'), () => ok(pageBody([row('b', 2), row('c', 3)], true))]);
    await act(async () => { r.current.openThread(THREAD); });
    expect(r.current.threadMessages.map((m) => m.id)).toEqual(['b', 'c']);
    expect(r.current.threadLoad).toBe('idle');
    expect(r.current.threadPage.hasMore).toBe(true);
    expect(urls.find(([u]) => u.includes('/threads/t1/messages?'))[0]).toContain('limit=30');
    await act(async () => { await r.current.loadOlderThread(); });
    expect(r.current.threadMessages.map((m) => m.id)).toEqual(['a', 'b', 'c']);
    expect(r.current.threadPage.hasMore).toBe(false);
    await act(async () => { await r.current.loadOlderThread(); });
    expect(urls.filter(([u]) => u.includes('cursor_id'))).toHaveLength(1);
  });
  test('first-page failure sets error; retry recovers', async () => {
    const r = await openGroup();
    routes.unshift([(u) => u.includes('/threads/t1/messages?'), () => fail(500)]);
    await act(async () => { r.current.openThread(THREAD); });
    expect(r.current.threadLoad).toBe('error');
    routes.shift();
    routes.push([(u) => u.includes('/threads/t1/messages?'), () => ok(pageBody([row('a', 1)], false))]);
    await act(async () => { r.current.retryThread(); });
    expect(r.current.threadLoad).toBe('idle');
    expect(r.current.threadMessages.map((m) => m.id)).toEqual(['a']);
  });
  test('404 closes the thread with an info toast', async () => {
    const r = await openGroup();
    routes.push([(u) => u.includes('/threads/t1/messages?'), () => fail(404)]);
    await act(async () => { r.current.openThread(THREAD); });
    expect(r.current.threadView).toBeNull();
    expect(message.info).toHaveBeenCalled();
  });
  test('closeThread resets state', async () => {
    const r = await openGroup();
    routes.push([(u) => u.includes('/threads/t1/messages?'), () => ok(pageBody([row('a', 1)], false))]);
    await act(async () => { r.current.openThread(THREAD); });
    act(() => { r.current.closeThread(); });
    expect(r.current.threadView).toBeNull();
    expect(r.current.threadMessages).toEqual([]);
  });
});

describe('thread send over the existing socket', () => {
  test('thread_message frame with thread_id, client_ref; ack reconciles thread list only', async () => {
    const r = await openGroup();
    routes.push([(u) => u.includes('/threads/t1/messages?'), () => ok(pageBody([], false))]);
    await act(async () => { r.current.openThread(THREAD); });
    act(() => { r.current.sendThreadMessage('hi thread'); });
    const sent = JSON.parse(ws().sent[0]);
    expect(sent).toMatchObject({ type: 'thread_message', thread_id: 't1', text: 'hi thread' });
    expect(typeof sent.client_ref).toBe('string');
    expect(MockWebSocket.instances).toHaveLength(1);
    expect(r.current.threadMessages[0]).toMatchObject({ pending: true, text: 'hi thread' });
    const mainCount = r.current.messages.length;
    frame({ type: 'ack', client_ref: sent.client_ref, id: 'tm1', thread_id: 't1', timestamp: ts(9) });
    expect(r.current.threadMessages).toHaveLength(1);
    expect(r.current.threadMessages[0].id).toBe('tm1');
    expect(r.current.threadMessages[0].pending).toBeFalsy();
    expect(r.current.messages).toHaveLength(mainCount);
  });
  test('terms_reaccept_required error frame refreshes capabilities and returns the text to the composer', async () => {
    const r = await openGroup();
    routes.push([(u) => u.includes('/threads/t1/messages?'), () => ok(pageBody([], false))]);
    await act(async () => { r.current.openThread(THREAD); });
    act(() => { r.current.sendThreadMessage('keep me'); });
    frame({ type: 'error', reason: 'terms_reaccept_required' });
    expect(refresh).toHaveBeenCalled();
    expect(r.current.threadMessages).toEqual([]);
    expect(r.current.restoredDraft).toMatchObject({ text: 'keep me' });
  });
  test('inbound thread_message for the open thread appends once; other thread ignored', async () => {
    const r = await openGroup();
    routes.push([(u) => u.includes('/threads/t1/messages?'), () => ok(pageBody([], false))]);
    await act(async () => { r.current.openThread(THREAD); });
    const f = { type: 'thread_message', thread_id: 't1', id: 'x1', body: 'yo', sender: 'ada', created_at: ts(5) };
    frame(f); frame(f);
    frame({ ...f, id: 'x2', thread_id: 'other' });
    expect(r.current.threadMessages.map((m) => m.id)).toEqual(['x1']);
    expect(r.current.messages.some((m) => m.id === 'x1')).toBe(false);
  });
});

describe('startThread', () => {
  test('success opens the thread', async () => {
    const r = await openGroup();
    routes.push([(u, o) => u.endsWith('/groups/u1/g1/threads') && o?.method === 'POST', () => ok(THREAD)]);
    routes.push([(u) => u.includes('/threads/t1/messages?'), () => ok(pageBody([], false))]);
    let res;
    await act(async () => { res = await r.current.startThread({ id: 'r1' }); });
    expect(res).toBe(true);
    expect(r.current.threadView.thread.id).toBe('t1');
  });
  test('403 terms_reaccept_required triggers the terms gate refresh', async () => {
    const r = await openGroup();
    routes.push([(u, o) => o?.method === 'POST', () => fail(403, { detail: { code: 'terms_reaccept_required', message: 'x' } })]);
    let res;
    await act(async () => { res = await r.current.startThread({ id: 'r1' }); });
    expect(res).toBe(false);
    expect(refresh).toHaveBeenCalled();
    expect(r.current.threadView).toBeNull();
  });
  test('thread_limit and generic failures show an error and do not refresh', async () => {
    const r = await openGroup();
    routes.push([(u, o) => o?.method === 'POST', () => fail(409, { detail: { code: 'thread_limit', message: 'x' } })]);
    await act(async () => { await r.current.startThread({ id: 'r1' }); });
    expect(message.error).toHaveBeenCalledWith(expect.stringContaining('thread limit'));
    expect(refresh).not.toHaveBeenCalled();
  });
});

describe('delete / restore', () => {
  test('optimistic removal, then restore puts it back at its time position', async () => {
    const r = await openGroup([row('r1', 1), row('m2', 2, { mine: true }), row('m3', 3)]);
    routes.push([(u, o) => o?.method === 'DELETE', () => ok({ id: 'm2', undo_seconds: 10 })]);
    routes.push([(u, o) => o?.method === 'POST' && u.endsWith('/restore'), () => ok({ id: 'm2' })]);
    let d;
    await act(async () => { d = await r.current.deleteMessage(r.current.messages[1]); });
    expect(d).toEqual({ id: 'm2', undoSeconds: 10 });
    expect(r.current.messages.map((m) => m.id)).toEqual(['r1', 'm3']);
    await act(async () => { await r.current.restoreMessage('m2'); });
    expect(r.current.messages.map((m) => m.id)).toEqual(['r1', 'm2', 'm3']);
  });
  test('failed delete rolls back and returns null', async () => {
    const r = await openGroup([row('r1', 1), row('m2', 2, { mine: true })]);
    routes.push([(u, o) => o?.method === 'DELETE', () => fail(500)]);
    let d;
    await act(async () => { d = await r.current.deleteMessage(r.current.messages[1]); });
    expect(d).toBeNull();
    expect(r.current.messages.map((m) => m.id)).toEqual(['r1', 'm2']);
    expect(message.error).toHaveBeenCalled();
  });
  test('restore after the window (server 4xx) leaves the message removed', async () => {
    const r = await openGroup([row('r1', 1), row('m2', 2, { mine: true })]);
    routes.push([(u, o) => o?.method === 'DELETE', () => ok({ id: 'm2', undo_seconds: 10 })]);
    routes.push([(u, o) => u.endsWith('/restore'), () => fail(410)]);
    await act(async () => { await r.current.deleteMessage(r.current.messages[1]); });
    let ok2;
    await act(async () => { ok2 = await r.current.restoreMessage('m2'); });
    expect(ok2).toBe(false);
    expect(r.current.messages.map((m) => m.id)).toEqual(['r1']);
  });
});

describe('websocket delete/restore frames', () => {
  test('message_deleted removes the row for the open group only', async () => {
    const r = await openGroup([row('r1', 1), row('m2', 2)]);
    frame({ type: 'message_deleted', id: 'm2', group_id: 'OTHER' });
    expect(r.current.messages).toHaveLength(2);
    frame({ type: 'message_deleted', id: 'm2', group_id: 'G1' });
    expect(r.current.messages.map((m) => m.id)).toEqual(['r1']);
    expect(MockWebSocket.instances).toHaveLength(1);
  });
  test('message_restored re-inserts by time and is idempotent', async () => {
    const r = await openGroup([row('r1', 1), row('m3', 3)]);
    const f = { type: 'message_restored', group_id: 'g1', id: 'm2', body: 'back', sender: 'ada', created_at: ts(2) };
    frame(f); frame(f);
    expect(r.current.messages.map((m) => m.id)).toEqual(['r1', 'm2', 'm3']);
  });
  test('root deleted frame marks the open thread header; restore clears it', async () => {
    const r = await openGroup();
    routes.push([(u) => u.includes('/threads/t1/messages?'), () => ok(pageBody([], false))]);
    await act(async () => { r.current.openThread(THREAD); });
    frame({ type: 'message_deleted', id: 'r1', group_id: 'g1' });
    expect(r.current.threadView.thread.root_deleted).toBe(true);
    frame({ type: 'message_restored', group_id: 'g1', id: 'r1', body: 'x', sender: 'ada', created_at: ts(1) });
    expect(r.current.threadView.thread.root_deleted).toBe(false);
  });
  test('delete/thread frames are never rendered as chat bubbles', async () => {
    const r = await openGroup([row('r1', 1)]);
    frame({ type: 'message_deleted', id: 'zzz', group_id: 'g1' });
    frame({ type: 'thread_message', thread_id: 'nope', id: 'q', body: 'b', created_at: ts(3) });
    expect(r.current.messages.map((m) => m.id)).toEqual(['r1']);
  });
});

describe('DM chat is unaffected', () => {
  test('startThread in a DM does nothing', async () => {
    routes.push([(u) => u.includes('/friends/u1/f1'), () => ok({ host_msgs: [], other_msgs: [] })]);
    const { result } = renderHook(() => useMessaging({ user: USER }), { wrapper });
    await act(async () => { await result.current.openChat(FRIEND); });
    let res;
    await act(async () => { res = await result.current.startThread({ id: 'r1' }); });
    expect(res).toBe(false);
    expect(urls.some(([u]) => u.includes('/threads'))).toBe(false);
  });
});
