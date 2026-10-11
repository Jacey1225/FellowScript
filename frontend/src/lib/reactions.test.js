// Task 20261011-desktop-chat-replies-reactions: reactions client + pure helpers
// (mirrors FellowScriptTests/ChatReactionsTests.swift).
import { describe, test, expect, vi, afterEach } from 'vitest';
import {
  parseSummary, parseReactions, toggled, setting, updatingCount, emojiName, chipLabel,
  addReaction, removeReaction, ReactionError, REACTION_FALLBACK,
} from './reactions.js';

afterEach(() => { vi.restoreAllMocks(); });
const resp = (status, body, bad) => ({ status, ok: status >= 200 && status < 300, json: bad ? () => Promise.reject(new Error('bad')) : () => Promise.resolve(body) });

describe('parsing', () => {
  test('valid summary', () => {
    expect(parseSummary({ emoji: '👍', count: 2, viewer_reacted: true })).toEqual({ emoji: '👍', count: 2, viewerReacted: true });
  });
  test.each([null, 'x', {}, { emoji: '', count: 1, viewer_reacted: true }, { emoji: '👍', count: -1, viewer_reacted: true },
    { emoji: '👍', count: 1.5, viewer_reacted: true }, { emoji: '👍', count: 1, viewer_reacted: 'yes' }])('malformed %j -> null', (v) => {
    expect(parseSummary(v)).toBeNull();
  });
  test('reactions: absent key -> undefined (flag off); zero-count and bad rows dropped', () => {
    expect(parseReactions(undefined)).toBeUndefined();
    expect(parseReactions('x')).toBeUndefined();
    expect(parseReactions([{ emoji: '👍', count: 0, viewer_reacted: false }, { bad: 1 }, { emoji: '🔥', count: 1, viewer_reacted: false }]))
      .toEqual([{ emoji: '🔥', count: 1, viewerReacted: false }]);
  });
});

describe('optimistic helpers', () => {
  const list = [{ emoji: '👍', count: 2, viewerReacted: false }, { emoji: '🔥', count: 1, viewerReacted: true }];
  test('toggled adds new emoji with count 1 viewer true', () => {
    expect(toggled(list, '🎉')).toEqual([...list, { emoji: '🎉', count: 1, viewerReacted: true }]);
  });
  test('toggled on an unreacted existing emoji increments', () => {
    expect(toggled(list, '👍')[0]).toEqual({ emoji: '👍', count: 3, viewerReacted: true });
  });
  test('toggled off own sole reaction drops the entry; with others decrements', () => {
    expect(toggled(list, '🔥')).toEqual([list[0]]);
    const two = [{ emoji: '🔥', count: 3, viewerReacted: true }];
    expect(toggled(two, '🔥')).toEqual([{ emoji: '🔥', count: 2, viewerReacted: false }]);
  });
  test('toggled does not mutate input', () => {
    const copy = JSON.parse(JSON.stringify(list));
    toggled(list, '👍'); toggled(list, '🔥');
    expect(list).toEqual(copy);
  });
  test('setting replaces, inserts, removes only that emoji (rollback)', () => {
    expect(setting(list, '👍', { emoji: '👍', count: 9, viewerReacted: true })[0].count).toBe(9);
    expect(setting(list, '👍', null)).toEqual([list[1]]);
    expect(setting(list, '🎉', null)).toBe(list);
    expect(setting(list, '🎉', { emoji: '🎉', count: 1, viewerReacted: true })).toHaveLength(3);
    expect(setting(list, '👍', { emoji: '👍', count: 0, viewerReacted: false })).toEqual([list[1]]);
  });
  test('updatingCount keeps the viewer state, never flips it', () => {
    expect(updatingCount(list, '🔥', 5)[1]).toEqual({ emoji: '🔥', count: 5, viewerReacted: true });
    expect(updatingCount(list, '👍', 4)[0]).toEqual({ emoji: '👍', count: 4, viewerReacted: false });
    expect(updatingCount(list, '🎉', 2).at(-1)).toEqual({ emoji: '🎉', count: 2, viewerReacted: false });
    expect(updatingCount(list, '👍', 0)).toEqual([list[1]]);
  });
});

describe('a11y names', () => {
  test('emojiName known and fallback never empty', () => {
    expect(emojiName('👍')).toBe('Thumbs up');
    expect(emojiName('🦄')).toBe('🦄');
  });
  test('chipLabel singular, plural, viewer', () => {
    expect(chipLabel({ emoji: '👍', count: 1, viewerReacted: false })).toBe('Thumbs up, 1 reaction');
    expect(chipLabel({ emoji: '👍', count: 3, viewerReacted: true })).toBe('Thumbs up, 3 reactions, you reacted');
  });
});

describe('network', () => {
  test('POST sends emoji body and parses summary', async () => {
    const f = vi.fn().mockResolvedValue(resp(200, { emoji: '👍', count: 1, viewer_reacted: true }));
    vi.stubGlobal('fetch', f);
    const r = await addReaction('u1', 'm1', '👍');
    expect(r).toEqual({ emoji: '👍', count: 1, viewerReacted: true });
    const [url, init] = f.mock.calls[0];
    expect(url).toContain('/message-reactions/u1/m1');
    expect(init.method).toBe('POST');
    expect(JSON.parse(init.body)).toEqual({ emoji: '👍' });
  });
  test('DELETE puts the encoded emoji in the query', async () => {
    const f = vi.fn().mockResolvedValue(resp(200, { emoji: '👍', count: 0, viewer_reacted: false }));
    vi.stubGlobal('fetch', f);
    await removeReaction('u1', 'm1', '👍');
    expect(f.mock.calls[0][0]).toContain(`?emoji=${encodeURIComponent('👍')}`);
    expect(f.mock.calls[0][1].method).toBe('DELETE');
  });
  test.each([
    [404, null, 'unavailable', "That message can't be reacted to anymore."],
    [429, null, 'rate', "You're reacting too quickly. Please wait a moment."],
    [403, { detail: { code: 'terms_reaccept_required' } }, 'terms', 'Please review and accept the updated Terms to continue.'],
    [409, { detail: { code: 'message_cap' } }, 'limit', 'This message has reached its reaction limit.'],
    [409, { detail: { code: 'user_cap' } }, 'limit', 'This message has reached its reaction limit.'],
    [500, null, 'failed', REACTION_FALLBACK],
    [403, { detail: { code: 'other' } }, 'failed', REACTION_FALLBACK],
  ])('status %s %j maps to %s', async (status, body, kind, msg) => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(resp(status, body)));
    const err = await addReaction('u1', 'm1', '👍').catch((e) => e);
    expect(err).toBeInstanceOf(ReactionError);
    expect(err.kind).toBe(kind);
    expect(err.message).toBe(msg);
  });
  test('transport error and undecodable/invalid success body throw (never fabricate)', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError('net')));
    await expect(addReaction('u1', 'm1', '👍')).rejects.toMatchObject({ kind: 'failed' });
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(resp(200, null, true)));
    await expect(addReaction('u1', 'm1', '👍')).rejects.toMatchObject({ kind: 'failed', message: REACTION_FALLBACK });
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(resp(200, { emoji: '👍' })));
    await expect(removeReaction('u1', 'm1', '👍')).rejects.toBeInstanceOf(ReactionError);
  });
});
