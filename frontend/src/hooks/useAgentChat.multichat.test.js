// Multi-chat behaviour of useAgentChat (flag agent_chats).
// Run: cd frontend && npx vitest run src/hooks/useAgentChat.multichat.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useAgentChat } from './useAgentChat.js';

const USER = { user_id: 'u1', username: 't' };
const AGENT = { id: 'a1', name: 'Mentor' };
const CHATS = [
  { id: 'c-new', title: 'Newest', created_at: '2026-10-13T10:00:00Z', last_message_at: '2026-10-14T10:00:00Z' },
  { id: 'c-old', title: 'Older', created_at: '2026-10-01T10:00:00Z', last_message_at: '2026-10-02T10:00:00Z' },
];

let sockets;
class FakeWS {
  constructor(url) { this.url = url; this.readyState = 1; this.sent = []; this.closed = false; sockets.push(this); }
  send(s) { this.sent.push(JSON.parse(s)); }
  close() { this.closed = true; }
}

const ok = (body, status = 200) => ({ ok: true, status, json: async () => body });
const bad = (status, body = {}) => ({ ok: false, status, json: async () => body });
const hist = (...texts) => Object.fromEntries(texts.map((t, i) => [`m${i}`, { content: t, title: 'user', timestamp: `2026-10-14T10:0${i}:00Z` }]));

// Route fetch by url; handlers is { match: fn(url, init) -> response }.
function route(handlers) {
  global.fetch = vi.fn(async (url, init) => {
    for (const [frag, h] of Object.entries(handlers)) {
      if (url.includes(frag)) return typeof h === 'function' ? h(url, init) : h;
    }
    return ok({});
  });
}
const calls = (frag) => global.fetch.mock.calls.filter(([u]) => u.includes(frag));

beforeEach(() => {
  sockets = [];
  vi.stubGlobal('WebSocket', FakeWS);
  const store = new Map();
  vi.stubGlobal('localStorage', { getItem: k => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v)) });
  vi.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); });

async function open(multiChat = true) {
  const hook = renderHook(() => useAgentChat({ user: USER, multiChat }));
  await act(async () => { await hook.result.current.openAgentChat(AGENT); });
  return hook;
}

describe('flag off (legacy)', () => {
  test('never calls /chats and never sends chat_id', async () => {
    route({ '/messages': ok(hist('hi')) });
    const { result } = await open(false);
    expect(calls('/chats')).toHaveLength(0);
    expect(global.fetch.mock.calls[0][0]).not.toContain('chat_id');
    expect(sockets[0].url).not.toContain('chat_id');
    act(() => result.current.sendAgentMessage('yo'));
    expect(sockets[0].sent[0]).toEqual({ content: 'yo' });
    expect(result.current.agentMessages.map(m => m.text)).toEqual(['hi', 'yo']);
  });
});

describe('flag on: open', () => {
  test('picks most recent, scopes history and socket by chat_id', async () => {
    route({ '/chats': ok({ chats: CHATS }), '/messages': ok(hist('a')) });
    const { result } = await open();
    expect(result.current.activeChatId).toBe('c-new');
    expect(result.current.chats.map(c => c.id)).toEqual(['c-new', 'c-old']); // server order kept
    expect(calls('/messages')[0][0]).toContain('?chat_id=c-new');
    expect(sockets[0].url).toContain('?chat_id=c-new');
  });

  test('restores last-visited chat per user+agent', async () => {
    localStorage.setItem('agentLastChat.u1.a1', 'c-old');
    route({ '/chats': ok({ chats: CHATS }), '/messages': ok(hist('a')) });
    const { result } = await open();
    expect(result.current.activeChatId).toBe('c-old');
  });

  test('stale last-visited falls back to most recent', async () => {
    localStorage.setItem('agentLastChat.u1.a1', 'deleted');
    route({ '/chats': ok({ chats: CHATS }), '/messages': ok([]) });
    const { result } = await open();
    expect(result.current.activeChatId).toBe('c-new');
  });

  test('list failure sets chatsError, invents no chats, uses default chat (no chat_id)', async () => {
    route({ '/chats': bad(500), '/messages': ok(hist('legacy')) });
    const { result } = await open();
    expect(result.current.chatsError).toBe("Couldn't load chats");
    expect(result.current.chats).toEqual([]);
    expect(result.current.activeChatId).toBeNull();
    expect(calls('/messages')[0][0]).not.toContain('chat_id');
    expect(result.current.agentMessages.map(m => m.text)).toEqual(['legacy']);
  });
});

describe('flag on: switch and send', () => {
  test('selectChat reloads that chat and reconnects socket; send carries chat_id', async () => {
    route({ '/chats': ok({ chats: CHATS }), '/messages': (u) => ok(hist(u.includes('c-old') ? 'old msg' : 'new msg')) });
    const { result } = await open();
    await act(async () => { await result.current.selectChat('c-old'); });
    expect(result.current.activeChatId).toBe('c-old');
    expect(result.current.agentMessages.map(m => m.text)).toEqual(['old msg']);
    expect(sockets[0].closed).toBe(true);
    expect(sockets[1].url).toContain('?chat_id=c-old');
    expect(localStorage.getItem('agentLastChat.u1.a1')).toBe('c-old');
    act(() => result.current.sendAgentMessage('hello'));
    expect(sockets[1].sent[0]).toEqual({ content: 'hello', chat_id: 'c-old' });
  });

  test('frames tagged for another chat are ignored', async () => {
    route({ '/chats': ok({ chats: CHATS }), '/messages': ok([]) });
    const { result } = await open();
    act(() => sockets[0].onmessage({ data: JSON.stringify({ content: 'x', chat_id: 'c-old', timestamp: 't' }) }));
    expect(result.current.agentMessages).toEqual([]);
    act(() => sockets[0].onmessage({ data: JSON.stringify({ content: 'y', chat_id: 'c-new', timestamp: 't' }) }));
    expect(result.current.agentMessages.map(m => m.text)).toEqual(['y']);
  });

  test('thinking reflects only the active chat', async () => {
    route({ '/chats': ok({ chats: CHATS }), '/messages': ok([]) });
    const { result } = await open();
    act(() => result.current.sendAgentMessage('q'));
    expect(result.current.agentThinking).toBe(true);
    await act(async () => { await result.current.selectChat('c-old'); });
    expect(result.current.agentThinking).toBe(false);
    await act(async () => { await result.current.selectChat('c-new'); });
    expect(result.current.agentThinking).toBe(true); // pending is tracked per chat and survives switching away
    act(() => sockets.at(-1).onmessage({ data: JSON.stringify({ content: 'a', chat_id: 'c-new', timestamp: 't' }) }));
    expect(result.current.agentThinking).toBe(false); // reply clears it
  });

  test('stale history response for a previously selected chat is discarded', async () => {
    let releaseOld;
    route({
      '/chats': ok({ chats: CHATS }),
      '/messages': (u) => u.includes('c-old')
        ? new Promise(r => { releaseOld = () => r(ok(hist('STALE'))); })
        : ok(hist('fresh')),
    });
    const { result } = await open();
    let pOld;
    act(() => { pOld = result.current.selectChat('c-old'); });
    await act(async () => { await result.current.selectChat('c-new').catch(() => {}); });
    // c-new is the first chat; selectChat('c-new') from c-old (in flight) activates it
    await act(async () => { releaseOld(); await pOld; });
    expect(result.current.activeChatId).toBe('c-new');
    expect(result.current.agentMessages.map(m => m.text)).not.toContain('STALE');
  });

  test('history failure keeps cached transcript and sets retryable historyError', async () => {
    let fail = false;
    route({ '/chats': ok({ chats: CHATS }), '/messages': () => (fail ? bad(500) : ok(hist('cached'))) });
    const { result } = await open();
    fail = true;
    await act(async () => { result.current.retryHistory(); });
    expect(result.current.historyError).toBe("Couldn't load this chat. Try again");
    expect(result.current.agentMessages.map(m => m.text)).toEqual(['cached']);
  });

  test('404 on a chat refetches the list and falls back', async () => {
    let n = 0;
    route({
      '/chats': () => ok({ chats: n++ ? [CHATS[0]] : CHATS }),
      '/messages': (u) => (u.includes('c-old') ? bad(404) : ok(hist('ok'))),
    });
    const { result } = await open();
    await act(async () => { await result.current.selectChat('c-old'); });
    expect(result.current.activeChatId).toBe('c-new');
    expect(result.current.chats.map(c => c.id)).toEqual(['c-new']);
  });
});

describe('flag on: create', () => {
  test('POST inserts at top, activates, clears transcript, stores last-visited', async () => {
    const created = { id: 'c-3', title: '', created_at: '2026-10-14T12:00:00Z', last_message_at: null };
    route({
      '/chats': (u, init) => (init?.method === 'POST' ? ok(created, 201) : ok({ chats: CHATS })),
      '/messages': ok(hist('prior')),
    });
    const { result } = await open();
    let chat;
    await act(async () => { chat = await result.current.createChat(); });
    expect(chat.id).toBe('c-3');
    expect(result.current.chats.map(c => c.id)).toEqual(['c-3', 'c-new', 'c-old']);
    expect(result.current.activeChatId).toBe('c-3');
    expect(result.current.agentMessages).toEqual([]);
    expect(localStorage.getItem('agentLastChat.u1.a1')).toBe('c-3');
    expect(sockets.at(-1).url).toContain('?chat_id=c-3');
  });

  test('409 chat_limit keeps current chat, shows limit copy, fabricates nothing', async () => {
    route({
      '/chats': (u, init) => (init?.method === 'POST' ? bad(409, { detail: { code: 'chat_limit' } }) : ok({ chats: CHATS })),
      '/messages': ok([]),
    });
    const { result } = await open();
    await act(async () => { await result.current.createChat(); });
    expect(result.current.createChatError).toBe("You've reached the limit of 50 chats with Mentor.");
    expect(result.current.activeChatId).toBe('c-new');
    expect(result.current.chats).toHaveLength(2);
  });

  test('network failure on create surfaces generic error', async () => {
    route({
      '/chats': (u, init) => { if (init?.method === 'POST') throw new Error('offline'); return ok({ chats: CHATS }); },
      '/messages': ok([]),
    });
    const { result } = await open();
    await act(async () => { await result.current.createChat(); });
    expect(result.current.createChatError).toMatch(/Couldn't start a new chat/);
    expect(result.current.activeChatId).toBe('c-new');
  });
});

describe('flag on: list refresh', () => {
  test('failed refresh preserves existing list and sets chatsError', async () => {
    let fail = false;
    route({ '/chats': () => (fail ? bad(500) : ok({ chats: CHATS })), '/messages': ok([]) });
    const { result } = await open();
    fail = true;
    await act(async () => { await result.current.refreshChats(); });
    expect(result.current.chatsError).toBe("Couldn't load chats");
    expect(result.current.chats).toHaveLength(2);
  });
});
