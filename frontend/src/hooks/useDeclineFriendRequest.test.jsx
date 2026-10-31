// Task 20261030-profile-everywhere (step 14): the Account Decline hook. The row
// leaves the list only after the server answers 204; on any failure the request
// stays and a warm message shows (throw-not-fabricate); 429 gets slow-down copy.
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { message } from 'antd';
import { useDeclineFriendRequest } from './useDeclineFriendRequest.js';
import { DECLINE_FAILURE } from '../lib/profileApi.js';

const ME = '11111111-1111-4111-8111-111111111111';
const A = '22222222-2222-4222-8222-222222222222';
const B = '33333333-3333-4333-8333-333333333333';
const rows = () => [{ uid: A, username: 'ann' }, { uid: B, username: 'bob' }];

let fetchMock;
const res = (status, body = {}) => ({ ok: status >= 200 && status < 300, status, json: async () => body });

// Harness: real React state for the list so the hook's functional update is exercised.
import { useState } from 'react';
function useHarness(userId = ME) {
  const [requests, setRequests] = useState(rows());
  return { requests, ...useDeclineFriendRequest(userId, setRequests) };
}

beforeEach(() => {
  fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);
  vi.spyOn(message, 'error').mockImplementation(() => {});
});
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe('useDeclineFriendRequest', () => {
  test('204: POSTs the recipient-only route and removes only that row', async () => {
    fetchMock.mockResolvedValue(res(204));
    const { result } = renderHook(() => useHarness());
    let ok;
    await act(async () => { ok = await result.current.decline(A); });
    expect(ok).toBe(true);
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toMatch(new RegExp(`/friends/${ME}/requests/${A}/decline$`));
    expect(opts.method).toBe('POST');
    expect(result.current.requests.map(r => r.uid)).toEqual([B]);
    expect(message.error).not.toHaveBeenCalled();
    expect(result.current.declining[A]).toBe(false);
  });

  test('500: row stays, warm decline copy, nothing fabricated', async () => {
    fetchMock.mockResolvedValue(res(500, {}));
    const { result } = renderHook(() => useHarness());
    let ok;
    await act(async () => { ok = await result.current.decline(A); });
    expect(ok).toBe(false);
    expect(result.current.requests.map(r => r.uid)).toEqual([A, B]);
    expect(message.error).toHaveBeenCalledWith(DECLINE_FAILURE);
  });

  test('network failure: row stays and warm copy shows', async () => {
    fetchMock.mockRejectedValue(new TypeError('offline'));
    const { result } = renderHook(() => useHarness());
    await act(async () => { await result.current.decline(A); });
    expect(result.current.requests.map(r => r.uid)).toEqual([A, B]);
    expect(message.error).toHaveBeenCalledWith(DECLINE_FAILURE);
  });

  test('429: row stays and the slow-down copy shows instead of the generic one', async () => {
    fetchMock.mockResolvedValue(res(429, { detail: 'Too many requests' }));
    const { result } = renderHook(() => useHarness());
    await act(async () => { await result.current.decline(A); });
    expect(result.current.requests.map(r => r.uid)).toEqual([A, B]);
    expect(message.error).toHaveBeenCalledTimes(1);
    const copy = message.error.mock.calls[0][0];
    expect(copy).toMatch(/slow down/i);
    expect(copy).not.toBe(DECLINE_FAILURE);
  });

  test('server error text is not surfaced to the user', async () => {
    fetchMock.mockResolvedValue(res(500, { detail: 'psycopg2 secret internals' }));
    const { result } = renderHook(() => useHarness());
    await act(async () => { await result.current.decline(A); });
    expect(JSON.stringify(message.error.mock.calls)).not.toContain('psycopg2');
  });

  test('no signed-in user id: no request is sent', async () => {
    const { result } = renderHook(() => useHarness(null));
    let ok;
    await act(async () => { ok = await result.current.decline(A); });
    expect(ok).toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(result.current.requests).toHaveLength(2);
  });

  test('a failed decline can be retried and then succeeds', async () => {
    fetchMock.mockResolvedValueOnce(res(500)).mockResolvedValueOnce(res(204));
    const { result } = renderHook(() => useHarness());
    await act(async () => { await result.current.decline(A); });
    expect(result.current.requests).toHaveLength(2);
    await act(async () => { await result.current.decline(A); });
    expect(result.current.requests.map(r => r.uid)).toEqual([B]);
  });
});
