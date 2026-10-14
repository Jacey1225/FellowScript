// Task 20261013-session-call-live-transcript-summary testing: summarize call-end
// retry when the server answers {ok:true, deferred:true}.
// Run: cd frontend && npx vitest run src/hooks/useAgentChat.summarizeDefer.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { message } from 'antd';
import { useAgentChat } from './useAgentChat.js';

const USER = { user_id: 'user-1', username: 'tester' };
const ok = (body) => ({ ok: true, status: 201, json: async () => body });

beforeEach(() => {
  global.fetch = vi.fn();
  vi.spyOn(message, 'error').mockImplementation(() => {});
  vi.useFakeTimers();
});
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });

const run = async (cb) => {
  const { result } = renderHook(() => useAgentChat({ user: USER }));
  let ret;
  await act(async () => { ret = await result.current.summarizeSession('agent-1', { id: 's1', title: 't' }, 'g1', cb); });
  return ret;
};

describe('summarizeSession deferred handling', () => {
  test('non-deferred success: one request, no retries, onGenerated not auto-called by first call', async () => {
    global.fetch.mockResolvedValue(ok({ ok: true, note_id: 'n' }));
    const cb = vi.fn();
    expect(await run(cb)).toBe(true);
    await act(async () => { await vi.advanceTimersByTimeAsync(200_000); });
    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(cb).not.toHaveBeenCalled();
  });

  test('deferred: retries the identical request ~50s later and calls onGenerated when generated', async () => {
    global.fetch.mockResolvedValueOnce(ok({ ok: true, deferred: true })).mockResolvedValueOnce(ok({ ok: true, note_id: 'n' }));
    const cb = vi.fn();
    expect(await run(cb)).toBe(true);
    expect(global.fetch).toHaveBeenCalledTimes(1);
    await act(async () => { await vi.advanceTimersByTimeAsync(49_000); });
    expect(global.fetch).toHaveBeenCalledTimes(1);
    await act(async () => { await vi.advanceTimersByTimeAsync(2_000); });
    expect(global.fetch).toHaveBeenCalledTimes(2);
    expect(global.fetch.mock.calls[1][1].body).toBe(global.fetch.mock.calls[0][1].body);
    expect(global.fetch.mock.calls[1][0]).toBe(global.fetch.mock.calls[0][0]);
    expect(cb).toHaveBeenCalledTimes(1);
    await act(async () => { await vi.advanceTimersByTimeAsync(200_000); });
    expect(global.fetch).toHaveBeenCalledTimes(2);
  });

  test('deferred forever: capped at 2 retries (3 requests total), onGenerated never called, no toast', async () => {
    global.fetch.mockResolvedValue(ok({ ok: true, deferred: true }));
    const cb = vi.fn();
    expect(await run(cb)).toBe(true);
    await act(async () => { await vi.advanceTimersByTimeAsync(400_000); });
    expect(global.fetch).toHaveBeenCalledTimes(3);
    expect(cb).not.toHaveBeenCalled();
    expect(message.error).not.toHaveBeenCalled();
  });

  test('retry error or non-ok stops silently (no toast)', async () => {
    global.fetch.mockResolvedValueOnce(ok({ ok: true, deferred: true })).mockRejectedValueOnce(new Error('net'));
    await run(vi.fn());
    await act(async () => { await vi.advanceTimersByTimeAsync(200_000); });
    expect(global.fetch).toHaveBeenCalledTimes(2);
    expect(message.error).not.toHaveBeenCalled();

    global.fetch.mockReset();
    global.fetch.mockResolvedValueOnce(ok({ ok: true, deferred: true })).mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) });
    await run(vi.fn());
    await act(async () => { await vi.advanceTimersByTimeAsync(200_000); });
    expect(global.fetch).toHaveBeenCalledTimes(2);
    expect(message.error).not.toHaveBeenCalled();
  });

  test('unparseable success body is treated as not deferred', async () => {
    global.fetch.mockResolvedValue({ ok: true, status: 201, json: async () => { throw new Error('bad'); } });
    expect(await run(vi.fn())).toBe(true);
    await act(async () => { await vi.advanceTimersByTimeAsync(200_000); });
    expect(global.fetch).toHaveBeenCalledTimes(1);
  });

  test('first call failure still surfaces the existing error toast and returns false', async () => {
    global.fetch.mockResolvedValue({ ok: false, status: 500, json: async () => ({}) });
    expect(await run(vi.fn())).toBe(false);
    expect(message.error).toHaveBeenCalled();
    await act(async () => { await vi.advanceTimersByTimeAsync(200_000); });
    expect(global.fetch).toHaveBeenCalledTimes(1);
  });
});
