// Ask AI mode of useAgentChat (flag ask_ai_default_agent): agent-id-free routes.
// Run: cd frontend && npx vitest run src/hooks/useAgentChat.askAi.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useAgentChat } from './useAgentChat.js';
import { ASK_AI_AGENT } from '../lib/agentChats.js';

const USER = { user_id: 'u1', username: 't' };
const CHATS = [
  { id: 'c1', title: 'One', created_at: '2026-10-13T10:00:00Z', last_message_at: '2026-10-14T10:00:00Z' },
  { id: 'c2', title: 'Two', created_at: '2026-10-01T10:00:00Z', last_message_at: '2026-10-02T10:00:00Z' },
];
let sockets;
class FakeWS {
  constructor(url) { this.url = url; this.readyState = 1; sockets.push(this); }
  send() {}
  close() {}
}
const ok = (body, status = 200) => ({ ok: true, status, json: async () => body });
const bad = (status, body = {}) => ({ ok: false, status, json: async () => body });
function route(handlers) {
  global.fetch = vi.fn(async (url, init) => {
    for (const [frag, h] of Object.entries(handlers)) {
      if (url.includes(frag)) return typeof h === 'function' ? h(url, init) : h;
    }
    return ok({});
  });
}
beforeEach(() => {
  sockets = [];
  vi.stubGlobal('WebSocket', FakeWS);
  const store = new Map();
  vi.stubGlobal('localStorage', { getItem: k => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v)) });
  vi.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe('Ask AI mode', () => {
  test('lists chats without an open thread and never sends an agent id', async () => {
    route({ '/ask-ai/u1/chats': ok({ chats: CHATS }) });
    const { result } = renderHook(() => useAgentChat({ user: USER, askAi: true }));
    await act(async () => { await result.current.refreshChats(); });
    expect(result.current.chats.map(c => c.id)).toEqual(['c1', 'c2']);
    expect(global.fetch.mock.calls.every(([u]) => !u.includes('/agent/'))).toBe(true);
  });

  test('open resumes the requested chat over the agent-id-free socket', async () => {
    route({ '/ask-ai/u1/chats': ok({ chats: CHATS }), '/ask-ai/u1/messages': ok({}) });
    const { result } = renderHook(() => useAgentChat({ user: USER, askAi: true }));
    await act(async () => { await result.current.openAgentChat(ASK_AI_AGENT, 'c2'); });
    expect(result.current.activeChatId).toBe('c2');
    expect(sockets[0].url).toContain('/ask-ai/ws/u1');
    expect(sockets[0].url).toContain('chat_id=c2');
  });

  test('failed refresh keeps the list and flags the error', async () => {
    route({ '/ask-ai/u1/chats': ok({ chats: CHATS }) });
    const { result } = renderHook(() => useAgentChat({ user: USER, askAi: true }));
    await act(async () => { await result.current.refreshChats(); });
    route({ '/ask-ai/u1/chats': bad(500) });
    await act(async () => { await result.current.refreshChats(); });
    expect(result.current.chats.map(c => c.id)).toEqual(['c1', 'c2']);
    expect(result.current.chatsError).toBeTruthy();
  });

  test('cold start with the network down shows the saved list, not an empty one', async () => {
    route({ '/ask-ai/u1/chats': ok({ chats: CHATS }) });
    const first = renderHook(() => useAgentChat({ user: USER, askAi: true }));
    await act(async () => { await first.result.current.refreshChats(); });
    route({ '/ask-ai/u1/chats': bad(503) });
    const second = renderHook(() => useAgentChat({ user: USER, askAi: true }));
    await act(async () => { await second.result.current.refreshChats(); });
    expect(second.result.current.chats.map(c => c.id)).toEqual(['c1', 'c2']);
    expect(second.result.current.chatsError).toBeTruthy();
  });

  test('chat limit uses Ask AI copy', async () => {
    route({ '/ask-ai/u1/chats': (u, init) => (init?.method === 'POST' ? bad(409, { detail: { code: 'chat_limit' } }) : ok({ chats: [] })) });
    const { result } = renderHook(() => useAgentChat({ user: USER, askAi: true }));
    await act(async () => { await result.current.createChat(); });
    expect(result.current.createChatError).toMatch(/chat limit/i);
    expect(result.current.createChatError).not.toMatch(/agent/i);
  });

  test('summarize goes to /ask-ai without an agent id', async () => {
    route({ '/ask-ai/u1/summarize': ok({}) });
    const { result } = renderHook(() => useAgentChat({ user: USER, askAi: true }));
    await act(async () => { await result.current.summarizeSession(ASK_AI_AGENT.id, { id: 's' }, 'g'); });
    expect(global.fetch.mock.calls[0][0]).toMatch(/\/ask-ai\/u1\/summarize$/);
  });
});
