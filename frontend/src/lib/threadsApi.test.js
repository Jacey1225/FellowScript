// Task 20261001-message-threads step 9: threads/message-delete API client + helpers.
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  listThreads, createThread, deleteGroupMessage, restoreGroupMessage, parseThreadsPage,
  insertRestored, relativeTime, ThreadsApiError, fetchThreadMessagesUrl, THREAD_LIST_LIMIT,
} from './threadsApi.js';

const res = (status, body) => ({ ok: status >= 200 && status < 300, status, json: async () => body });
let calls;
beforeEach(() => { calls = []; });
afterEach(() => { vi.restoreAllMocks(); });
const mockFetch = (r) => { global.fetch = vi.fn(async (url, opts) => { calls.push([String(url), opts]); if (r instanceof Error) throw r; return r; }); };

describe('requests', () => {
  test('listThreads hits the group threads route with limit and cursor', async () => {
    mockFetch(res(200, { threads: [{ id: 't1' }, { nope: 1 }], page: { has_more: true, next_cursor_timestamp: '2026-10-01T10:00:00Z', next_cursor_id: 't1' } }));
    const out = await listThreads('u 1', 'g1', { timestamp: 'ts', id: 'c' });
    expect(calls[0][0]).toContain('/groups/u%201/g1/threads?');
    expect(calls[0][0]).toContain(`limit=${THREAD_LIST_LIMIT}`);
    expect(calls[0][0]).toContain('cursor_id=c');
    expect(out.threads).toEqual([{ id: 't1' }]);
    expect(out.hasMore).toBe(true);
    expect(out.cursor).toEqual({ timestamp: '2026-10-01T10:00:00Z', id: 't1' });
  });
  test('createThread POSTs message_id', async () => {
    mockFetch(res(200, { id: 't1' }));
    await createThread('u1', 'g1', 'm1');
    expect(calls[0][1].method).toBe('POST');
    expect(JSON.parse(calls[0][1].body)).toEqual({ message_id: 'm1' });
  });
  test('delete uses DELETE and restore uses POST /restore', async () => {
    mockFetch(res(200, { id: 'm1', undo_seconds: 10 }));
    await deleteGroupMessage('u1', 'g1', 'm1');
    await restoreGroupMessage('u1', 'g1', 'm1');
    expect(calls[0][0]).toMatch(/\/groups\/u1\/g1\/messages\/m1$/);
    expect(calls[0][1].method).toBe('DELETE');
    expect(calls[1][0]).toMatch(/\/messages\/m1\/restore$/);
    expect(calls[1][1].method).toBe('POST');
  });
  test('thread messages url carries cursor', () => {
    const u = fetchThreadMessagesUrl('u1', 'g1', 't1', 30, { timestamp: 'x', seq: 3, id: 'c' });
    expect(u).toContain('/threads/t1/messages?limit=30');
    expect(u).toContain('cursor_seq=3');
  });
});

describe('errors throw, never fabricate', () => {
  test('structured detail exposes status and code', async () => {
    mockFetch(res(403, { detail: { code: 'terms_reaccept_required', message: 'accept' } }));
    await expect(createThread('u', 'g', 'm')).rejects.toMatchObject({ name: 'ThreadsApiError', status: 403, code: 'terms_reaccept_required', message: 'accept' });
  });
  test('string detail and fallback copy', async () => {
    mockFetch(res(409, { detail: 'full' }));
    await expect(createThread('u', 'g', 'm')).rejects.toMatchObject({ status: 409, message: 'full', code: null });
    global.fetch = vi.fn(async () => ({ ok: false, status: 500, json: async () => { throw new Error('x'); } }));
    await expect(deleteGroupMessage('u', 'g', 'm')).rejects.toMatchObject({ status: 500, message: "Couldn't delete that message. Please try again." });
  });
  test('network failure has status 0', async () => {
    mockFetch(new Error('offline'));
    const e = await listThreads('u', 'g').catch((x) => x);
    expect(e).toBeInstanceOf(ThreadsApiError);
    expect(e.status).toBe(0);
  });
});

describe('helpers', () => {
  test('parseThreadsPage: has_more without a cursor is the end; garbage is empty', () => {
    expect(parseThreadsPage({ threads: [], page: { has_more: true } })).toEqual({ threads: [], hasMore: false, cursor: null });
    expect(parseThreadsPage(null)).toEqual({ threads: [], hasMore: false, cursor: null });
  });
  test('insertRestored puts the row at its time position and dedups by id', () => {
    const a = { id: 'a', timestamp: '2026-10-01T10:00:01Z' };
    const c = { id: 'c', timestamp: '2026-10-01T10:00:03Z' };
    const b = { id: 'b', timestamp: '2026-10-01T10:00:02Z' };
    expect(insertRestored([a, c], b).map((m) => m.id)).toEqual(['a', 'b', 'c']);
    expect(insertRestored([a, b, c], b)).toEqual([a, b, c]);
    expect(insertRestored([a, b], c).map((m) => m.id)).toEqual(['a', 'b', 'c']);
    expect(insertRestored([a], { id: 'z', timestamp: 'bad' }).map((m) => m.id)).toEqual(['a', 'z']);
  });
  test('relativeTime', () => {
    const now = Date.parse('2026-10-01T12:00:00Z');
    expect(relativeTime('2026-10-01T11:59:50Z', now)).toBe('just now');
    expect(relativeTime('2026-10-01T11:30:00Z', now)).toBe('30m ago');
    expect(relativeTime('2026-10-01T09:00:00Z', now)).toBe('3h ago');
    expect(relativeTime('2026-09-29T12:00:00Z', now)).toBe('2d ago');
    expect(relativeTime('garbage', now)).toBe('');
  });
});
