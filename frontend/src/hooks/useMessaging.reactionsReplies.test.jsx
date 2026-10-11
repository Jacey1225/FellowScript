// Task 20261011-desktop-chat-replies-reactions: useMessaging reactions + replies.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { message } from 'antd';
import { useMessaging } from './useMessaging.js';
import { CapabilitiesContext } from '../context/CapabilitiesContext.jsx';

const USER = { user_id: 'u1', username: 'tester' };
const GROUP = { id: 'g1', type: 'group', group_id: 'g1', toUsers: ['u1'] };
const DM = { id: 'f1', type: 'friend', group_id: '', toUsers: ['f1'] };

class MockWebSocket {
  static instances = [];
  constructor(url) { this.url = url; this.readyState = 1; this.sent = []; MockWebSocket.instances.push(this); }
  close() { this.readyState = 3; }
  send(d) { this.sent.push(d); }
}
const ts = (n) => `2026-10-01T10:00:${String(n).padStart(2, '0')}.000000Z`;
const row = (id, n, over = {}) => ({ id, text: `t-${id}`, timestamp: ts(n), from_user: 'ada', mine: false, ...over });
const ok = (body) => ({ ok: true, status: 200, json: async () => body });
const fail = (status, body = {}) => ({ ok: false, status, json: async () => body });
const body = (rows) => ({ messages: rows, page: { has_more: false } });

let refresh; let features; let routes; let urls;
const wrapper = ({ children }) => (
  <CapabilitiesContext.Provider value={{
    features,
    isEnabled: (k) => features[k] === true,
    refresh,
    reactionEmoji: { quick: ['👍', '❤️'], more: ['🔥'] },
  }}
  >{children}</CapabilitiesContext.Provider>
);
beforeEach(() => {
  MockWebSocket.instances = [];
  global.WebSocket = MockWebSocket;
  refresh = vi.fn();
  features = { message_reactions: true, chat_replies: true };
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
const reactionRoute = (fn) => routes.push([(u) => u.includes('/message-reactions/u1/'), fn]);

async function open(rows, contact = GROUP) {
  routes.push([(u) => /\/groups\/u1\/g1(\?|$)/.test(u), () => ok({ group: { title: 'G', users: ['u1'] }, ...body(rows) })]);
  routes.push([(u) => /\/friends\/u1\/f1(\?|$)/.test(u), () => ok(body(rows))]);
  const { result } = renderHook(() => useMessaging({ user: USER }), { wrapper });
  act(() => { result.current.connectWS(); });
  await act(async () => { await result.current.openChat(contact); });
  return result;
}
const byId = (r, id) => r.current.messages.find((m) => m.id === id);
const R = (emoji, count, viewer) => ({ emoji, count, viewer_reacted: viewer });

describe('history rows', () => {
  test('reactions and reply fields are carried onto messages', async () => {
    const r = await open([row('m1', 1, { reactions: [R('👍', 2, true)], reply_to_id: 'm0', reply_to_text: 'orig', reply_to_author: 'bob', reply_to_author_id: 'u9' })]);
    const m = byId(r, 'm1');
    expect(m.reactions).toEqual([{ emoji: '👍', count: 2, viewerReacted: true }]);
    expect(m.reply).toMatchObject({ id: 'm0', text: 'orig', author: 'bob', deleted: false });
  });
  test('rows without the keys get neither (flag-off payload)', async () => {
    const r = await open([row('m1', 1)]);
    expect(byId(r, 'm1').reactions).toBeUndefined();
    expect(byId(r, 'm1').reply).toBeUndefined();
  });
});

describe('toggleReaction', () => {
  test('optimistic add, then server summary replaces it; POST body has emoji', async () => {
    const r = await open([row('m1', 1, { reactions: [R('👍', 1, false)] })]);
    let release;
    reactionRoute(() => new Promise((res) => { release = () => res(ok({ emoji: '👍', count: 2, viewer_reacted: true })); }));
    let p;
    act(() => { p = r.current.toggleReaction(byId(r, 'm1'), '👍'); });
    expect(byId(r, 'm1').reactions).toEqual([{ emoji: '👍', count: 2, viewerReacted: true }]);
    await act(async () => { release(); await p; });
    expect(byId(r, 'm1').reactions[0]).toEqual({ emoji: '👍', count: 2, viewerReacted: true });
    const call = urls.find(([u]) => u.includes('/message-reactions/'));
    expect(call[1].method).toBe('POST');
    expect(JSON.parse(call[1].body)).toEqual({ emoji: '👍' });
  });
  test('removing own reaction sends DELETE and drops the chip at zero', async () => {
    const r = await open([row('m1', 1, { reactions: [R('👍', 1, true)] })]);
    reactionRoute(() => ok({ emoji: '👍', count: 0, viewer_reacted: false }));
    await act(async () => { await r.current.toggleReaction(byId(r, 'm1'), '👍'); });
    expect(urls.find(([u]) => u.includes('/message-reactions/'))[1].method).toBe('DELETE');
    expect(byId(r, 'm1').reactions).toEqual([]);
  });
  test('failure rolls back exactly that emoji and shows the mapped message', async () => {
    const r = await open([row('m1', 1, { reactions: [R('👍', 1, false), R('🔥', 4, true)] })]);
    reactionRoute(() => fail(409, { detail: { code: 'message_cap' } }));
    let res;
    await act(async () => { res = await r.current.toggleReaction(byId(r, 'm1'), '👍'); });
    expect(res).toBe(false);
    expect(byId(r, 'm1').reactions).toEqual([{ emoji: '👍', count: 1, viewerReacted: false }, { emoji: '🔥', count: 4, viewerReacted: true }]);
    expect(message.error).toHaveBeenCalledWith(expect.objectContaining({ content: 'This message has reached its reaction limit.' }));
  });
  test('rolling back a brand-new reaction removes the optimistic chip', async () => {
    const r = await open([row('m1', 1)]);
    reactionRoute(() => fail(500));
    await act(async () => { await r.current.toggleReaction(byId(r, 'm1'), '👍'); });
    expect(byId(r, 'm1').reactions).toEqual([]);
    expect(message.error).toHaveBeenCalled();
  });
  test('429 shows the rate message without crashing', async () => {
    const r = await open([row('m1', 1)]);
    reactionRoute(() => fail(429));
    await act(async () => { await r.current.toggleReaction(byId(r, 'm1'), '👍'); });
    expect(message.error).toHaveBeenCalledWith(expect.objectContaining({ content: "You're reacting too quickly. Please wait a moment." }));
  });
  test('terms failure refreshes capabilities', async () => {
    const r = await open([row('m1', 1)]);
    reactionRoute(() => fail(403, { detail: { code: 'terms_reaccept_required' } }));
    await act(async () => { await r.current.toggleReaction(byId(r, 'm1'), '👍'); });
    expect(refresh).toHaveBeenCalled();
  });
  test('second tap on the same emoji while in flight is ignored', async () => {
    const r = await open([row('m1', 1)]);
    let release;
    reactionRoute(() => new Promise((res) => { release = () => res(ok({ emoji: '👍', count: 1, viewer_reacted: true })); }));
    let p; let second;
    act(() => { p = r.current.toggleReaction(byId(r, 'm1'), '👍'); });
    await act(async () => { second = await r.current.toggleReaction(byId(r, 'm1'), '👍'); });
    expect(second).toBe(false);
    await act(async () => { release(); await p; });
    expect(urls.filter(([u]) => u.includes('/message-reactions/'))).toHaveLength(1);
  });
  test('flag off: no request, no change', async () => {
    features = { message_reactions: false, chat_replies: false };
    const r = await open([row('m1', 1)]);
    let res;
    await act(async () => { res = await r.current.toggleReaction(byId(r, 'm1'), '👍'); });
    expect(res).toBe(false);
    expect(urls.some(([u]) => u.includes('/message-reactions/'))).toBe(false);
    expect(byId(r, 'm1').reactions).toBeUndefined();
  });
  test('pending or failed local messages are not reactable', async () => {
    const r = await open([row('m1', 1)]);
    let res;
    await act(async () => { res = await r.current.toggleReaction({ id: 'x', pending: true }, '👍'); });
    expect(res).toBe(false);
    await act(async () => { res = await r.current.toggleReaction({ text: 'no id' }, '👍'); });
    expect(res).toBe(false);
    expect(urls.some(([u]) => u.includes('/message-reactions/'))).toBe(false);
  });
});

describe('reaction_updated frames', () => {
  const upd = (over = {}) => ({ type: 'reaction_updated', message_id: 'm1', group_id: 'g1', emoji: '👍', count: 3, actor_id: 'u2', ...over });
  test('updates the count live and never renders a bubble', async () => {
    const r = await open([row('m1', 1, { reactions: [R('👍', 1, false)] })]);
    const n = r.current.messages.length;
    frame(upd());
    expect(r.current.messages).toHaveLength(n);
    expect(byId(r, 'm1').reactions).toEqual([{ emoji: '👍', count: 3, viewerReacted: false }]);
  });
  test('own actor does not flip viewer_reacted; other actor does not clear it', async () => {
    const r = await open([row('m1', 1, { reactions: [R('👍', 1, true)] })]);
    frame(upd({ count: 2, actor_id: 'u1' }));
    expect(byId(r, 'm1').reactions[0]).toEqual({ emoji: '👍', count: 2, viewerReacted: true });
    frame(upd({ count: 5, actor_id: 'u2' }));
    expect(byId(r, 'm1').reactions[0]).toEqual({ emoji: '👍', count: 5, viewerReacted: true });
  });
  test('new emoji from someone else appears unreacted; count 0 removes', async () => {
    const r = await open([row('m1', 1)]);
    frame(upd({ emoji: '🔥', count: 1 }));
    expect(byId(r, 'm1').reactions).toEqual([{ emoji: '🔥', count: 1, viewerReacted: false }]);
    frame(upd({ emoji: '🔥', count: 0 }));
    expect(byId(r, 'm1').reactions).toEqual([]);
  });
  test('other conversation, unknown message, malformed frames are ignored', async () => {
    const r = await open([row('m1', 1, { reactions: [R('👍', 1, false)] })]);
    const before = JSON.stringify(r.current.messages);
    frame(upd({ group_id: 'other' }));
    frame(upd({ message_id: 'nope' }));
    frame(upd({ count: 'x' }));
    frame(upd({ count: -1 }));
    frame(upd({ emoji: '' }));
    frame({ type: 'reaction_updated' });
    expect(JSON.stringify(r.current.messages)).toBe(before);
  });
  test('flag off: frame ignored', async () => {
    features = { message_reactions: false };
    const r = await open([row('m1', 1)]);
    frame(upd());
    expect(byId(r, 'm1').reactions).toBeUndefined();
  });
  test('DM room key a|b matches the open DM', async () => {
    const r = await open([row('m1', 1)], DM);
    frame(upd({ group_id: 'f1|u1' }));
    expect(byId(r, 'm1').reactions).toEqual([{ emoji: '👍', count: 3, viewerReacted: false }]);
    frame(upd({ group_id: 'f1|zz', emoji: '🔥' }));
    expect(byId(r, 'm1').reactions).toHaveLength(1);
  });
});

describe('replies', () => {
  const reply = { id: 'm1', text: 'orig', author: 'ada', authorId: 'u2', deleted: false };
  const sentFrames = () => ws().sent.map((s) => JSON.parse(s));

  test('sendMessage with reply sends reply_to and shows the optimistic quote', async () => {
    const r = await open([row('m1', 1)]);
    act(() => { r.current.sendMessage('answer', null, reply); });
    expect(sentFrames()[0].reply_to).toBe('m1');
    expect(r.current.messages.at(-1)).toMatchObject({ text: 'answer', reply });
  });
  test('without a reply the payload has no reply_to key', async () => {
    const r = await open([row('m1', 1)]);
    act(() => { r.current.sendMessage('plain'); });
    expect('reply_to' in sentFrames()[0]).toBe(false);
    expect(r.current.messages.at(-1).reply).toBeUndefined();
  });
  test('chat_replies off: reply argument is dropped entirely', async () => {
    features = { message_reactions: true, chat_replies: false };
    const r = await open([row('m1', 1)]);
    act(() => { r.current.sendMessage('answer', null, reply); });
    expect('reply_to' in sentFrames()[0]).toBe(false);
    expect(r.current.messages.at(-1).reply).toBeUndefined();
  });
  test('malformed reply argument is ignored', async () => {
    const r = await open([row('m1', 1)]);
    act(() => { r.current.sendMessage('x', null, { id: 5 }); });
    expect('reply_to' in sentFrames()[0]).toBe(false);
  });
  test('inbound live frame carries reply fields onto the bubble', async () => {
    const r = await open([row('m1', 1)]);
    frame({ from_user: 'ada', text: 'hey', timestamp: ts(7), group_id: 'g1', id: 'm9', reply_to_id: 'm1', reply_to_text: 'orig', reply_to_author: 'tester', reply_to_author_id: 'u1' });
    expect(byId(r, 'm9').reply).toMatchObject({ id: 'm1', text: 'orig', authorId: 'u1' });
  });
  test('inbound frame for a deleted original is marked deleted with no text', async () => {
    const r = await open([row('m1', 1)]);
    frame({ from_user: 'ada', text: 'hey', timestamp: ts(7), group_id: 'g1', id: 'm9', reply_to_id: 'm1', reply_to_deleted: true, reply_to_text: 'leak' });
    expect(byId(r, 'm9').reply).toMatchObject({ id: 'm1', deleted: true, text: null });
  });
  test('reply_invalid error frame clears the reply on the failed bubble and shows a notice', async () => {
    const r = await open([row('m1', 1)]);
    act(() => { r.current.sendMessage('answer', null, reply); });
    frame({ type: 'error', reason: 'reply_invalid' });
    const failed = r.current.messages.at(-1);
    expect(failed.failed).toBe(true);
    expect(failed.reply).toBeUndefined();
    expect(failed.text).toBe('answer');
    expect(message.error).toHaveBeenCalledWith(expect.objectContaining({ content: expect.stringContaining("can't be replied to") }));
    // retry sends it plain
    act(() => { r.current.retryFailedMessage(failed); });
    expect('reply_to' in sentFrames().at(-1)).toBe(false);
  });
  test('retry of an ordinary failed reply preserves the reply', async () => {
    const r = await open([row('m1', 1)]);
    ws().readyState = 3; // offline -> failed bubble
    act(() => { r.current.sendMessage('later', null, reply); });
    const failed = r.current.messages.at(-1);
    expect(failed).toMatchObject({ failed: true, reply });
    ws().readyState = 1;
    act(() => { r.current.retryFailedMessage(failed); });
    expect(sentFrames().at(-1)).toMatchObject({ text: 'later', reply_to: 'm1' });
    expect(r.current.messages.at(-1).reply).toEqual(reply);
  });
});
