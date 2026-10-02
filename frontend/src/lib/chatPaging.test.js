// Task 20261001-chat-pagination step 8: pure paging helpers.
import { describe, test, expect } from 'vitest';
import {
  parsePage, pageQuery, mergeOlder, mergeLive, reconcileAck, findLostAckMatch, newClientRef,
  ACK_MATCH_WINDOW_MS,
} from './chatPaging.js';

const row = (id, text = id, extra = {}) => ({ id, text, timestamp: '2026-10-01T10:00:00.000000Z', from_user: 'ada', mine: false, ...extra });

describe('parsePage', () => {
  test('legacy shapes return null', () => {
    expect(parsePage(null)).toBeNull();
    expect(parsePage({ host_msgs: [], other_msgs: [] })).toBeNull();
    expect(parsePage({ messages: [] })).toBeNull();
    expect(parsePage({ page: { has_more: false }, messages: 'x' })).toBeNull();
  });
  test('keeps server order and maps rows', () => {
    const pg = parsePage({ messages: [row('b'), row('a')], page: { has_more: false } });
    expect(pg.messages.map(m => m.id)).toEqual(['b', 'a']);
    expect(pg.messages[0].key).toBe('b');
    expect(pg.hasMore).toBe(false);
    expect(pg.cursor).toBeNull();
  });
  test('has_more with usable cursor', () => {
    const pg = parsePage({ messages: [], page: { has_more: true, next_cursor_timestamp: 't', next_cursor_seq: 7, next_cursor_id: 'i' } });
    expect(pg.hasMore).toBe(true);
    expect(pg.cursor).toEqual({ timestamp: 't', seq: 7, id: 'i' });
  });
  test('has_more without a cursor is treated as the end', () => {
    const pg = parsePage({ messages: [], page: { has_more: true } });
    expect(pg.hasMore).toBe(false);
    expect(pg.cursor).toBeNull();
  });
  test('missing seq becomes null', () => {
    const pg = parsePage({ messages: [], page: { has_more: true, next_cursor_timestamp: 't', next_cursor_id: 'i' } });
    expect(pg.cursor.seq).toBeNull();
  });
  test('attachment_key is never surfaced', () => {
    const pg = parsePage({ messages: [row('a', 'x', { attachment_key: 'secret', attachment_kind: 'image', attachment_url: 'u' })], page: { has_more: false } });
    expect(JSON.stringify(pg.messages[0])).not.toContain('secret');
    expect(pg.messages[0].attachmentKind).toBe('image');
  });
});

describe('pageQuery', () => {
  test('encodes the offset plus sign and omits null seq', () => {
    const q = pageQuery(30, { timestamp: '2026-10-01T10:00:00+00:00', seq: null, id: 'abc' });
    expect(q).toContain('limit=30');
    expect(q).toContain('cursor_timestamp=2026-10-01T10%3A00%3A00%2B00%3A00');
    expect(q).not.toContain('cursor_seq');
    expect(q).toContain('cursor_id=abc');
  });
  test('includes seq incl. 0; no cursor means limit only', () => {
    expect(pageQuery(30, { timestamp: 't', seq: 0, id: 'i' })).toContain('cursor_seq=0');
    expect(pageQuery(5, null)).toBe('limit=5');
  });
});

describe('merge', () => {
  test('mergeOlder prepends and skips ids already present', () => {
    const cur = [{ id: 'c' }, { id: 'd' }];
    expect(mergeOlder(cur, [{ id: 'a' }, { id: 'b' }, { id: 'c' }]).map(m => m.id)).toEqual(['a', 'b', 'c', 'd']);
  });
  test('mergeOlder with all duplicates returns the same array', () => {
    const cur = [{ id: 'c' }];
    expect(mergeOlder(cur, [{ id: 'c' }])).toBe(cur);
  });
  test('mergeOlder does not re-sort by timestamp string', () => {
    const cur = [{ id: 'z', timestamp: '2026-01-01' }];
    const out = mergeOlder(cur, [{ id: 'y', timestamp: '2027-01-01' }]);
    expect(out.map(m => m.id)).toEqual(['y', 'z']);
  });
  test('mergeLive dedups by id, appends otherwise, keeps id-less frames', () => {
    const cur = [{ id: 'a' }];
    expect(mergeLive(cur, { id: 'a' })).toBe(cur);
    expect(mergeLive(cur, { id: 'b' }).map(m => m.id)).toEqual(['a', 'b']);
    expect(mergeLive(cur, { text: 'legacy' })).toHaveLength(2);
  });
  test('pending bubbles survive merges', () => {
    const cur = [{ clientRef: 'r', pending: true }, { id: 'c' }];
    expect(mergeOlder(cur, [{ id: 'a' }]).filter(m => m.pending)).toHaveLength(1);
  });
});

describe('reconcileAck', () => {
  const pending = { clientRef: 'r1', pending: true, key: 'c:r1', text: 'hi', timestamp: 'T0' };
  test('replaces in place, keeps position, clears pending', () => {
    const cur = [{ id: 'a' }, pending, { id: 'z' }];
    const out = reconcileAck(cur, { client_ref: 'r1', id: 'm9', timestamp: 'T1' });
    expect(out).toHaveLength(3);
    expect(out[1]).toMatchObject({ id: 'm9', pending: false, timestamp: 'T1', text: 'hi' });
  });
  test('deletes the optimistic bubble when the id already exists', () => {
    const cur = [{ id: 'm9' }, pending];
    const out = reconcileAck(cur, { client_ref: 'r1', id: 'm9' });
    expect(out).toEqual([{ id: 'm9' }]);
  });
  test('unknown client_ref is a no-op', () => {
    const cur = [pending];
    expect(reconcileAck(cur, { client_ref: 'nope', id: 'x' })).toBe(cur);
  });
});

describe('findLostAckMatch', () => {
  const t0 = '2026-10-01T10:00:00.000Z';
  const pend = { text: 'hello', attachmentKind: null, timestamp: t0 };
  const mine = (id, over = {}) => ({ id, mine: true, text: 'hello', attachmentKind: null, timestamp: t0, ...over });
  test('matches text + kind within the window', () => {
    expect(findLostAckMatch([], pend, [mine('m1')]).id).toBe('m1');
  });
  test('rejects other users, other text, other kind, outside window, already present', () => {
    expect(findLostAckMatch([], pend, [mine('a', { mine: false })])).toBeNull();
    expect(findLostAckMatch([], pend, [mine('a', { text: 'bye' })])).toBeNull();
    expect(findLostAckMatch([], pend, [mine('a', { attachmentKind: 'image' })])).toBeNull();
    const far = new Date(Date.parse(t0) + ACK_MATCH_WINDOW_MS + 1000).toISOString();
    expect(findLostAckMatch([], pend, [mine('a', { timestamp: far })])).toBeNull();
    expect(findLostAckMatch([{ id: 'a' }], pend, [mine('a')])).toBeNull();
  });
  test('closest in time wins', () => {
    const near = new Date(Date.parse(t0) + 1000).toISOString();
    const farther = new Date(Date.parse(t0) + 60000).toISOString();
    expect(findLostAckMatch([], pend, [mine('far', { timestamp: farther }), mine('near', { timestamp: near })]).id).toBe('near');
  });
});

describe('newClientRef', () => {
  test('matches the server pattern and is unique', () => {
    const a = newClientRef(); const b = newClientRef();
    expect(a).toMatch(/^[A-Za-z0-9_-]{1,64}$/);
    expect(a).not.toBe(b);
  });
});
