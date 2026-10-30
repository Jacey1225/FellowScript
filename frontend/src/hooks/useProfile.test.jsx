// Task 20261030-user-profiles testing step 8: cache-then-refresh semantics.
import React from 'react';
import { describe, test, expect, vi, beforeEach } from 'vitest';
import { renderHook, waitFor, act } from '@testing-library/react';

const fetchProfile = vi.fn();
vi.mock('../lib/profileApi.js', () => ({ fetchProfile: (...a) => fetchProfile(...a) }));

import { useProfile } from './useProfile.js';
import { getCachedProfile, setCachedProfile, clearProfileCache } from '../lib/profileCache.js';

const err = (status) => Object.assign(new Error('x'), { status });
const P = { user_id: 't', username: 'ann', relationship: { state: 'friends' }, bio: 'hi' };

beforeEach(() => { clearProfileCache(); fetchProfile.mockReset(); });

describe('useProfile', () => {
  test('first load success -> ready and cached', async () => {
    fetchProfile.mockResolvedValue(P);
    const { result } = renderHook(() => useProfile('v', 't'));
    expect(result.current.state).toBe('loading');
    await waitFor(() => expect(result.current.state).toBe('ready'));
    expect(result.current.profile).toEqual(P);
    expect(getCachedProfile('v', 't')).toEqual(P);
  });

  test('first load network failure with no cache -> error, never a fabricated profile', async () => {
    fetchProfile.mockRejectedValue(err(0));
    const { result } = renderHook(() => useProfile('v', 't'));
    await waitFor(() => expect(result.current.state).toBe('error'));
    expect(result.current.profile).toBeNull();
  });

  test('404 on first load -> unavailable', async () => {
    fetchProfile.mockRejectedValue(err(404));
    const { result } = renderHook(() => useProfile('v', 't'));
    await waitFor(() => expect(result.current.state).toBe('unavailable'));
  });

  test('cached profile renders immediately (ready) while refreshing', async () => {
    setCachedProfile('v', 't', P);
    let resolve;
    fetchProfile.mockReturnValue(new Promise((r) => { resolve = r; }));
    const { result } = renderHook(() => useProfile('v', 't'));
    expect(result.current.state).toBe('ready');
    expect(result.current.profile).toEqual(P);
    await waitFor(() => expect(result.current.refreshing).toBe(true));
    await act(async () => { resolve({ ...P, bio: 'new' }); });
    await waitFor(() => expect(result.current.profile.bio).toBe('new'));
    expect(result.current.refreshing).toBe(false);
  });

  test('network failure keeps the cached profile and flags refreshFailed', async () => {
    setCachedProfile('v', 't', P);
    fetchProfile.mockRejectedValue(err(0));
    const { result } = renderHook(() => useProfile('v', 't'));
    await waitFor(() => expect(result.current.refreshFailed).toBe(true));
    expect(result.current.state).toBe('ready');
    expect(result.current.profile).toEqual(P);
    expect(getCachedProfile('v', 't')).toEqual(P);
  });

  test('5xx keeps the cached profile too', async () => {
    setCachedProfile('v', 't', P);
    fetchProfile.mockRejectedValue(err(503));
    const { result } = renderHook(() => useProfile('v', 't'));
    await waitFor(() => expect(result.current.refreshFailed).toBe(true));
    expect(result.current.profile).toEqual(P);
  });

  test('404 evicts the cache and shows unavailable', async () => {
    setCachedProfile('v', 't', P);
    fetchProfile.mockRejectedValue(err(404));
    const { result } = renderHook(() => useProfile('v', 't'));
    await waitFor(() => expect(result.current.state).toBe('unavailable'));
    expect(result.current.profile).toBeNull();
    expect(getCachedProfile('v', 't')).toBeNull();
  });

  test('patch updates state and cache; drop evicts', async () => {
    fetchProfile.mockResolvedValue(P);
    const { result } = renderHook(() => useProfile('v', 't'));
    await waitFor(() => expect(result.current.state).toBe('ready'));
    act(() => result.current.patch((p) => ({ ...p, bio: 'edited' })));
    expect(result.current.profile.bio).toBe('edited');
    expect(getCachedProfile('v', 't').bio).toBe('edited');
    act(() => result.current.drop());
    expect(result.current.state).toBe('unavailable');
    expect(getCachedProfile('v', 't')).toBeNull();
  });

  test('reload after a failed refresh can recover', async () => {
    setCachedProfile('v', 't', P);
    fetchProfile.mockRejectedValueOnce(err(0)).mockResolvedValueOnce({ ...P, bio: 'fresh' });
    const { result } = renderHook(() => useProfile('v', 't'));
    await waitFor(() => expect(result.current.refreshFailed).toBe(true));
    await act(async () => { await result.current.reload(); });
    await waitFor(() => expect(result.current.profile.bio).toBe('fresh'));
    expect(result.current.refreshFailed).toBe(false);
  });
});
