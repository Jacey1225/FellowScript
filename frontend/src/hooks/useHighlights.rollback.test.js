// Regression tests for task 20260904-compliance-error-handling-consistency's
// fix to useHighlights.js (spec finding H9): setHighlight/clearHighlight
// used to swallow every failure with a bare `catch {}`, leaving the
// optimistic highlight mutation applied even when the server never
// actually persisted it. This now logs, surfaces a visible antd
// `message.error`, and rolls back the optimistic state on failure
// (Architecture Q27: propagate failures upward rather than silently
// substituting a default).
//
// Run with: cd frontend && npm test -- --run src/hooks/useHighlights.rollback.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { message } from 'antd';
import { useHighlights } from './useHighlights.js';

const USER = { user_id: 'user-1', username: 'tester' };

function fetchHooks() {
  return renderHook(() => useHighlights({ user: USER, curBook: 'John', curChapter: 3 }));
}

beforeEach(() => {
  global.fetch = vi.fn();
  vi.spyOn(message, 'error').mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('useHighlights.setHighlight — rolls back the optimistic write on failure', () => {
  test('a non-ok response rolls back a brand-new highlight and surfaces message.error', async () => {
    global.fetch.mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) });
    const { result } = fetchHooks();

    await act(async () => { await result.current.setHighlight(16, '#ffcc00'); });

    expect(result.current.localHl['John-3-16']).toBeUndefined();
    expect(message.error).toHaveBeenCalled();
  });

  test('a rejected fetch (network failure) also rolls back and surfaces message.error', async () => {
    global.fetch.mockRejectedValueOnce(new Error('network down'));
    const { result } = fetchHooks();

    await act(async () => { await result.current.setHighlight(16, '#ffcc00'); });

    expect(result.current.localHl['John-3-16']).toBeUndefined();
    expect(message.error).toHaveBeenCalled();
  });

  test('a failure changing an existing highlight color restores the previous color rather than deleting it', async () => {
    global.fetch.mockResolvedValueOnce({ ok: true, status: 200, json: async () => ({}) });
    const { result } = fetchHooks();
    await act(async () => { await result.current.setHighlight(16, '#ffcc00'); });
    expect(result.current.localHl['John-3-16']).toBe('#ffcc00');

    global.fetch.mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) });
    await act(async () => { await result.current.setHighlight(16, '#00ccff'); });

    expect(result.current.localHl['John-3-16']).toBe('#ffcc00');
  });

  test('a successful save keeps the optimistic highlight applied (no rollback, no error)', async () => {
    global.fetch.mockResolvedValueOnce({ ok: true, status: 200, json: async () => ({}) });
    const { result } = fetchHooks();

    await act(async () => { await result.current.setHighlight(16, '#ffcc00'); });

    expect(result.current.localHl['John-3-16']).toBe('#ffcc00');
    expect(message.error).not.toHaveBeenCalled();
  });
});

describe('useHighlights.clearHighlight — rolls back the optimistic delete on failure', () => {
  test('a non-ok, non-204 response restores the cleared highlight and surfaces message.error', async () => {
    global.fetch.mockResolvedValueOnce({ ok: true, status: 200, json: async () => ({}) });
    const { result } = fetchHooks();
    await act(async () => { await result.current.setHighlight(16, '#ffcc00'); });

    global.fetch.mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) });
    await act(async () => { await result.current.clearHighlight(16); });

    expect(result.current.localHl['John-3-16']).toBe('#ffcc00');
    expect(message.error).toHaveBeenCalled();
  });

  test('a rejected fetch also restores the cleared highlight and surfaces message.error', async () => {
    global.fetch.mockResolvedValueOnce({ ok: true, status: 200, json: async () => ({}) });
    const { result } = fetchHooks();
    await act(async () => { await result.current.setHighlight(16, '#ffcc00'); });

    global.fetch.mockRejectedValueOnce(new Error('network down'));
    await act(async () => { await result.current.clearHighlight(16); });

    expect(result.current.localHl['John-3-16']).toBe('#ffcc00');
    expect(message.error).toHaveBeenCalled();
  });

  test('a 204 response is treated as success -- no rollback, no error', async () => {
    global.fetch.mockResolvedValueOnce({ ok: true, status: 200, json: async () => ({}) });
    const { result } = fetchHooks();
    await act(async () => { await result.current.setHighlight(16, '#ffcc00'); });

    global.fetch.mockResolvedValueOnce({ ok: false, status: 204, json: async () => ({}) });
    await act(async () => { await result.current.clearHighlight(16); });

    expect(result.current.localHl['John-3-16']).toBeUndefined();
    expect(message.error).not.toHaveBeenCalled();
  });
});
