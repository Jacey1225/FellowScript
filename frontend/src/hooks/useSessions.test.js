// Regression tests for task 20260904-compliance-reliability-bugs's fix to
// useSessions.js's joinSession: Chime call-join used to fail completely
// silently on a meeting-creation or attendee-token fetch error (no error, no
// retry, no signal whatsoever) -- this now surfaces an explicit, retryable
// `joinError` state instead, matching the already-fixed iOS
// CallController.joinError behavior (Architecture Q27: propagate failures
// upward rather than silently substituting a default / doing nothing).
//
// Run with: cd frontend && npm test -- --run src/hooks/useSessions.test.js
import { describe, test, expect, vi, beforeEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useSessions } from './useSessions.js';

const USER = { user_id: 'user-1', username: 'tester' };
const SESSION_ID = 'session-1';

function okJson(body = {}) {
  return { ok: true, status: 200, json: async () => body };
}

function fetchHooks({ user = USER, currentContact = null } = {}) {
  const wsRef = { current: { readyState: 0, send: vi.fn() } };
  return renderHook(() => useSessions({ user, wsRef, currentContact }));
}

beforeEach(() => {
  global.fetch = vi.fn();
});

describe('joinSession — surfaces a visible, retryable error instead of failing silently', () => {
  test('a failed meeting-creation response (non-ok) sets joinError with a user-facing message', async () => {
    global.fetch
      .mockResolvedValueOnce(okJson({}))              // 1. join-participants POST (ignored errors)
      .mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) }); // 2. chime meeting POST fails

    const { result } = fetchHooks();
    await act(async () => { await result.current.joinSession(SESSION_ID); });

    expect(result.current.joinError).toEqual({
      sessionId: SESSION_ID,
      message: 'Could not start the call. Please try again.',
    });
  });

  test('a thrown/network-failure on the meeting-creation fetch sets a distinct "could not reach the server" message', async () => {
    global.fetch
      .mockResolvedValueOnce(okJson({}))                 // join-participants POST
      .mockRejectedValueOnce(new Error('network down'));  // chime meeting POST throws

    const { result } = fetchHooks();
    await act(async () => { await result.current.joinSession(SESSION_ID); });

    expect(result.current.joinError).toEqual({
      sessionId: SESSION_ID,
      message: 'Could not reach the server to start the call.',
    });
  });

  test('a failed attendee-token response (non-ok) sets joinError distinct from the meeting-creation failure', async () => {
    global.fetch
      .mockResolvedValueOnce(okJson({}))                                  // join-participants POST
      .mockResolvedValueOnce(okJson({ Meeting: { MeetingId: 'm-1' } }))   // chime meeting POST succeeds
      .mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) }); // attendee POST fails

    const { result } = fetchHooks();
    await act(async () => { await result.current.joinSession(SESSION_ID); });

    expect(result.current.joinError).toEqual({
      sessionId: SESSION_ID,
      message: 'Could not join the call. Please try again.',
    });
  });

  test('a thrown/network-failure on the attendee-token fetch also sets a distinct "could not reach the server" message', async () => {
    global.fetch
      .mockResolvedValueOnce(okJson({}))
      .mockResolvedValueOnce(okJson({ Meeting: { MeetingId: 'm-1' } }))
      .mockRejectedValueOnce(new Error('network down'));

    const { result } = fetchHooks();
    await act(async () => { await result.current.joinSession(SESSION_ID); });

    expect(result.current.joinError).toEqual({
      sessionId: SESSION_ID,
      message: 'Could not reach the server to join the call.',
    });
  });

  test('clearJoinError resets joinError to null (Dismiss affordance)', async () => {
    global.fetch
      .mockResolvedValueOnce(okJson({}))
      .mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) });

    const { result } = fetchHooks();
    await act(async () => { await result.current.joinSession(SESSION_ID); });
    expect(result.current.joinError).not.toBeNull();

    act(() => { result.current.clearJoinError(); });
    expect(result.current.joinError).toBeNull();
  });

  test('starting a new join attempt (Retry) clears any stale error from a previous attempt before hitting the network again', async () => {
    // First attempt fails outright.
    global.fetch
      .mockResolvedValueOnce(okJson({}))
      .mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) });
    const { result } = fetchHooks();
    await act(async () => { await result.current.joinSession(SESSION_ID); });
    expect(result.current.joinError).not.toBeNull();

    // Retry: the join-participants fetch resolves, but the meeting-creation
    // fetch is left pending (never resolves in this tick) so we can observe
    // the synchronous "clear stale error" reset before any new network
    // response has come back.
    let resolveJoinCall;
    global.fetch
      .mockImplementationOnce(() => new Promise(resolve => { resolveJoinCall = resolve; }))
      .mockImplementationOnce(() => new Promise(() => {})); // never resolves

    act(() => { result.current.joinSession(SESSION_ID); });
    expect(result.current.joinError).toBeNull();

    // Let the pending join-participants call resolve so there's no dangling
    // unhandled state; the meeting fetch is intentionally left hanging.
    resolveJoinCall?.(okJson({}));
  });
});
