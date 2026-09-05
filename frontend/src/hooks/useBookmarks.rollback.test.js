// Regression tests for task 20260904-compliance-error-handling-consistency's
// fix to useBookmarks.js (spec finding H9): addBookmark/removeBookmark used
// to swallow every failure with a bare `catch {}`, leaving the optimistic
// bookmark mutation applied even when the server never actually persisted
// it. This now logs, surfaces a visible antd `message.error`, and rolls
// back the optimistic state on failure (Architecture Q27: propagate
// failures upward rather than silently substituting a default).
//
// Run with: cd frontend && npm test -- --run src/hooks/useBookmarks.rollback.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { message } from 'antd';
import { useBookmarks } from './useBookmarks.js';

const USER = { user_id: 'user-1', username: 'tester' };

beforeEach(() => {
  global.fetch = vi.fn();
  vi.spyOn(message, 'error').mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('useBookmarks.addBookmark — rolls back the optimistic write on failure', () => {
  test('a non-ok response rolls back a brand-new bookmark and surfaces message.error', async () => {
    global.fetch.mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) });
    const { result } = renderHook(() => useBookmarks({ user: USER }));

    await act(async () => { await result.current.addBookmark('John', 3, 'my label'); });

    expect(result.current.bookmarks['John-3']).toBeUndefined();
    expect(message.error).toHaveBeenCalled();
  });

  test('a rejected fetch (network failure) also rolls back and surfaces message.error', async () => {
    global.fetch.mockRejectedValueOnce(new Error('network down'));
    const { result } = renderHook(() => useBookmarks({ user: USER }));

    await act(async () => { await result.current.addBookmark('John', 3); });

    expect(result.current.bookmarks['John-3']).toBeUndefined();
    expect(message.error).toHaveBeenCalled();
  });

  test('a failure overwriting an existing bookmark restores its previous label rather than deleting it', async () => {
    // First, succeed to seed an existing bookmark.
    global.fetch.mockResolvedValueOnce({ ok: true, status: 200, json: async () => ({}) });
    const { result } = renderHook(() => useBookmarks({ user: USER }));
    await act(async () => { await result.current.addBookmark('John', 3, 'old label'); });
    expect(result.current.bookmarks['John-3']).toBe('old label');

    // Now overwrite it with a label change that fails server-side.
    global.fetch.mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) });
    await act(async () => { await result.current.addBookmark('John', 3, 'new label'); });

    expect(result.current.bookmarks['John-3']).toBe('old label');
  });

  test('a successful save keeps the optimistic bookmark applied (no rollback, no error)', async () => {
    global.fetch.mockResolvedValueOnce({ ok: true, status: 200, json: async () => ({}) });
    const { result } = renderHook(() => useBookmarks({ user: USER }));

    await act(async () => { await result.current.addBookmark('John', 3, 'my label'); });

    expect(result.current.bookmarks['John-3']).toBe('my label');
    expect(message.error).not.toHaveBeenCalled();
  });
});

describe('useBookmarks.removeBookmark — rolls back the optimistic delete on failure', () => {
  test('a non-ok, non-204 response restores the removed bookmark and surfaces message.error', async () => {
    global.fetch.mockResolvedValueOnce({ ok: true, status: 200, json: async () => ({}) });
    const { result } = renderHook(() => useBookmarks({ user: USER }));
    await act(async () => { await result.current.addBookmark('John', 3, 'my label'); });
    expect(result.current.bookmarks['John-3']).toBe('my label');

    global.fetch.mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) });
    await act(async () => { await result.current.removeBookmark('John-3'); });

    expect(result.current.bookmarks['John-3']).toBe('my label');
    expect(message.error).toHaveBeenCalled();
  });

  test('a rejected fetch also restores the removed bookmark and surfaces message.error', async () => {
    global.fetch.mockResolvedValueOnce({ ok: true, status: 200, json: async () => ({}) });
    const { result } = renderHook(() => useBookmarks({ user: USER }));
    await act(async () => { await result.current.addBookmark('John', 3, 'my label'); });

    global.fetch.mockRejectedValueOnce(new Error('network down'));
    await act(async () => { await result.current.removeBookmark('John-3'); });

    expect(result.current.bookmarks['John-3']).toBe('my label');
    expect(message.error).toHaveBeenCalled();
  });

  test('a 204 response is treated as success -- no rollback, no error', async () => {
    global.fetch.mockResolvedValueOnce({ ok: true, status: 200, json: async () => ({}) });
    const { result } = renderHook(() => useBookmarks({ user: USER }));
    await act(async () => { await result.current.addBookmark('John', 3, 'my label'); });

    global.fetch.mockResolvedValueOnce({ ok: false, status: 204, json: async () => ({}) });
    await act(async () => { await result.current.removeBookmark('John-3'); });

    expect(result.current.bookmarks['John-3']).toBeUndefined();
    expect(message.error).not.toHaveBeenCalled();
  });
});
