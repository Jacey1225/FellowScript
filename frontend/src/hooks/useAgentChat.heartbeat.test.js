// Regression tests for task 20260904-compliance-error-handling-consistency's
// heartbeat monitor fixes in useAgentChat.js:
//
//   H7 — the monitor used to mark a heartbeat "fired" for the day BEFORE its
//   commit_heartbeat POST was confirmed to succeed, so a failed check-in
//   silently never happened again for the rest of the day. It now only
//   marks "fired" after a confirmed 2xx response, logs + surfaces a visible
//   antd message.error on failure, and lets the next 60s tick retry.
//
//   logic-errors #4 — the monitor used to require the current tick to land
//   on the *exact* scheduled minute, so a throttled/backgrounded tab or a
//   late app-open past the scheduled time meant the check-in was silently
//   lost for the rest of the day. It now fires as soon as "now" is at or
//   past today's scheduled time (catch-up/tolerance), not only exactly at it.
//
// Run with: cd frontend && npm test -- --run src/hooks/useAgentChat.heartbeat.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { message } from 'antd';
import { useAgentChat } from './useAgentChat.js';

const USER = { user_id: 'user-1', username: 'tester' };

function pad(n) { return String(n).padStart(2, '0'); }

// Fixed mid-morning time on "today" (whatever today happens to be when the
// suite runs) -- avoids midnight-rollover edge cases while still deriving
// `days_per_week` from the real weekday so the heartbeat's day-match check
// passes regardless of when the suite is run.
function fixedNow() {
  const now = new Date();
  now.setHours(10, 5, 0, 0);
  return now;
}

beforeEach(() => {
  global.fetch = vi.fn();
  vi.spyOn(message, 'error').mockImplementation(() => {});
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

async function seedHeartbeat(result, heartbeat) {
  global.fetch.mockResolvedValueOnce({ ok: true, status: 200, json: async () => [heartbeat] });
  await act(async () => { await result.current.loadHeartbeats([{ id: 'agent-1' }]); });
}

describe('useAgentChat heartbeat monitor — fired-before-confirmed fix (H7)', () => {
  test('does not mark a heartbeat "fired" until its POST is confirmed -- a failed check-in retries on the next tick', async () => {
    const now = fixedNow();
    const dayName = now.toLocaleDateString('en-US', { weekday: 'long' });
    vi.setSystemTime(now);

    const { result } = renderHook(() => useAgentChat({ user: USER }));
    await seedHeartbeat(result, {
      _id: 'hb-1',
      timestamp: `2020-01-01T${pad(now.getHours())}:${pad(now.getMinutes())}:00`,
      days_per_week: [dayName],
      prompt: 'Daily check-in',
    });

    // Tick 1: the commit_heartbeat POST fails.
    global.fetch.mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) });
    await act(async () => { await vi.advanceTimersByTimeAsync(60_000); });
    expect(global.fetch).toHaveBeenCalledTimes(2); // seed load + this failed attempt
    expect(message.error).toHaveBeenCalledWith(expect.objectContaining({ key: 'fs-heartbeat-hb-1' }));

    // Tick 2 (still the same day): since the failed attempt was never
    // marked "fired", the monitor must retry rather than silently giving up
    // for the rest of the day.
    global.fetch.mockResolvedValueOnce({ ok: true, status: 200, json: async () => ({ success: true }) });
    await act(async () => { await vi.advanceTimersByTimeAsync(60_000); });
    expect(global.fetch).toHaveBeenCalledTimes(3);
  });

  test('a successful check-in marks the heartbeat fired for the day -- no duplicate POST on the next tick', async () => {
    const now = fixedNow();
    const dayName = now.toLocaleDateString('en-US', { weekday: 'long' });
    vi.setSystemTime(now);

    const { result } = renderHook(() => useAgentChat({ user: USER }));
    await seedHeartbeat(result, {
      _id: 'hb-2',
      timestamp: `2020-01-01T${pad(now.getHours())}:${pad(now.getMinutes())}:00`,
      days_per_week: [dayName],
      prompt: 'Daily check-in',
    });

    global.fetch.mockResolvedValueOnce({ ok: true, status: 200, json: async () => ({ success: true }) });
    await act(async () => { await vi.advanceTimersByTimeAsync(60_000); });
    expect(global.fetch).toHaveBeenCalledTimes(2);
    expect(message.error).not.toHaveBeenCalled();

    // Next tick, same day -- must not re-fire.
    await act(async () => { await vi.advanceTimersByTimeAsync(60_000); });
    expect(global.fetch).toHaveBeenCalledTimes(2);
  });
});

describe('useAgentChat heartbeat monitor — missed/delayed-tick catch-up tolerance (logic-errors #4)', () => {
  test('a heartbeat scheduled earlier today (missed tick) still fires -- no exact-minute match required', async () => {
    const now = fixedNow();
    const dayName = now.toLocaleDateString('en-US', { weekday: 'long' });
    const scheduled = new Date(now.getTime() - 10 * 60_000); // 10 minutes ago
    vi.setSystemTime(now);

    const { result } = renderHook(() => useAgentChat({ user: USER }));
    await seedHeartbeat(result, {
      _id: 'hb-3',
      timestamp: `2020-01-01T${pad(scheduled.getHours())}:${pad(scheduled.getMinutes())}:00`,
      days_per_week: [dayName],
      prompt: 'Daily check-in',
    });

    global.fetch.mockResolvedValueOnce({ ok: true, status: 200, json: async () => ({ success: true }) });
    await act(async () => { await vi.advanceTimersByTimeAsync(60_000); });

    expect(global.fetch).toHaveBeenCalledTimes(2);
    expect(global.fetch.mock.calls[1][0]).toContain('/commit_heartbeat');
  });

  test('a heartbeat scheduled later today does not fire yet', async () => {
    const now = fixedNow();
    const dayName = now.toLocaleDateString('en-US', { weekday: 'long' });
    const scheduled = new Date(now.getTime() + 10 * 60_000); // 10 minutes from now
    vi.setSystemTime(now);

    const { result } = renderHook(() => useAgentChat({ user: USER }));
    await seedHeartbeat(result, {
      _id: 'hb-4',
      timestamp: `2020-01-01T${pad(scheduled.getHours())}:${pad(scheduled.getMinutes())}:00`,
      days_per_week: [dayName],
      prompt: 'Daily check-in',
    });

    await act(async () => { await vi.advanceTimersByTimeAsync(60_000); });
    expect(global.fetch).toHaveBeenCalledTimes(1); // only the seed load, no commit_heartbeat
  });
});
