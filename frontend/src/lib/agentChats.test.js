// Multi-chat helpers (flag agent_chats). Run: cd frontend && npx vitest run src/lib/agentChats.test.js
import { describe, test, expect, vi, beforeEach } from 'vitest';
import {
  lastChatKey, readLastChat, writeLastChat, pickInitialChatId, chatDisplayTitle,
  chatDateLabel, chatActivityIso, AgentChatHttpError, createChatErrorMessage,
} from './agentChats.js';

beforeEach(() => {
  const store = new Map();
  vi.stubGlobal('localStorage', {
    getItem: k => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
  });
});

describe('last-visited chat', () => {
  test('key matches iOS agentLastChat.<user>.<agent>', () => {
    expect(lastChatKey('u1', 'a1')).toBe('agentLastChat.u1.a1');
  });
  test('write then read round-trips per user+agent', () => {
    writeLastChat('u1', 'a1', 'c9');
    expect(readLastChat('u1', 'a1')).toBe('c9');
    expect(readLastChat('u1', 'a2')).toBeNull();
    expect(readLastChat('u2', 'a1')).toBeNull();
  });
  test('storage that throws is best-effort', () => {
    vi.stubGlobal('localStorage', { getItem: () => { throw new Error('x'); }, setItem: () => { throw new Error('x'); } });
    expect(readLastChat('u', 'a')).toBeNull();
    expect(() => writeLastChat('u', 'a', 'c')).not.toThrow();
  });
});

describe('pickInitialChatId', () => {
  const chats = [{ id: 'new' }, { id: 'mid' }, { id: 'old' }];
  test('uses last-visited when still in list', () => expect(pickInitialChatId(chats, 'mid')).toBe('mid'));
  test('stale last-visited falls back to most recent', () => expect(pickInitialChatId(chats, 'gone')).toBe('new'));
  test('no last-visited gives most recent', () => expect(pickInitialChatId(chats, null)).toBe('new'));
  test('empty list gives null (nothing fabricated)', () => {
    expect(pickInitialChatId([], 'x')).toBeNull();
    expect(pickInitialChatId(undefined, null)).toBeNull();
  });
});

describe('labels', () => {
  const now = new Date(2026, 9, 14, 15, 0, 0);
  test('Today / Yesterday / short date', () => {
    expect(chatDateLabel(new Date(2026, 9, 14, 1).toISOString(), now)).toBe('Today');
    expect(chatDateLabel(new Date(2026, 9, 13, 23).toISOString(), now)).toBe('Yesterday');
    expect(chatDateLabel(new Date(2026, 9, 4, 12).toISOString(), now)).toBe('Oct 4');
  });
  test('unparseable or missing gives empty string', () => {
    expect(chatDateLabel('nope', now)).toBe('');
    expect(chatDateLabel(null, now)).toBe('');
  });
  test('blank title becomes New chat', () => {
    expect(chatDisplayTitle({ title: '  ' })).toBe('New chat');
    expect(chatDisplayTitle({ title: 'Grace' })).toBe('Grace');
  });
  test('activity falls back to created_at', () => {
    expect(chatActivityIso({ last_message_at: 'a', created_at: 'b' })).toBe('a');
    expect(chatActivityIso({ created_at: 'b' })).toBe('b');
  });
});

describe('createChatErrorMessage', () => {
  test('409 chat_limit names the cap and agent', () => {
    expect(createChatErrorMessage(new AgentChatHttpError(409, 'chat_limit'), 'Mentor'))
      .toBe("You've reached the limit of 50 chats with Mentor.");
  });
  test('409 without chat_limit code is generic', () => {
    expect(createChatErrorMessage(new AgentChatHttpError(409), 'M')).toMatch(/Couldn't start/);
  });
  test('429, 404, other', () => {
    expect(createChatErrorMessage(new AgentChatHttpError(429), 'M')).toMatch(/Slow down/);
    expect(createChatErrorMessage(new AgentChatHttpError(404), 'M')).toMatch(/no longer available/);
    expect(createChatErrorMessage(new Error('x'), 'M')).toMatch(/Couldn't start/);
  });
});
