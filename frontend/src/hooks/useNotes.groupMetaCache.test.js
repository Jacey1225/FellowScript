// Regression test for task 20260904-compliance-performance-fixes, step 3
// (High H13, frontend-only fix): loadGroups() previously re-fetched every
// group's title on EVERY call via /groups/{user_id}/{gid}, mirroring
// useMessaging.js's same N+1 pattern. groupMetaCache (keyed by group id) now
// dedupes a repeat loadGroups() call so an already-resolved group's title
// isn't re-fetched, while a genuinely new group id still fetches fresh.
//
// Run with: cd frontend && npm test -- --run src/hooks/useNotes.groupMetaCache.test.js
import { describe, test, expect, vi, beforeEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { message } from 'antd';
import { useNotes } from './useNotes.js';

const USER = { user_id: 'user-1', username: 'tester' };

function countCalls(fetchMock, substring) {
  return fetchMock.mock.calls.filter(([url]) => url.includes(substring)).length;
}

beforeEach(() => {
  vi.spyOn(message, 'error').mockImplementation(() => {});
  vi.spyOn(message, 'warning').mockImplementation(() => {});
});

describe('useNotes.loadGroups — groupMetaCache dedup (H13)', () => {
  test('a second loadGroups() call reuses the cached group title instead of re-fetching it', async () => {
    global.fetch = vi.fn(async (url) => {
      if (url.includes('/user/user-1')) return { ok: true, json: async () => ({ groups: ['group-1'] }) };
      if (url.includes('/groups/user-1/group-1')) return { ok: true, json: async () => ({ group: { title: 'First Title' } }) };
      return { ok: false, status: 404, json: async () => ({}) };
    });
    const { result } = renderHook(() => useNotes({ user: USER }));

    await act(async () => { await result.current.loadGroups(); });
    expect(countCalls(global.fetch, '/groups/user-1/group-1')).toBe(1);
    expect(result.current.groups).toEqual([{ id: 'group-1', title: 'First Title' }]);

    // Swap the mock so a stale cache read would be detectable, then reload.
    global.fetch = vi.fn(async (url) => {
      if (url.includes('/user/user-1')) return { ok: true, json: async () => ({ groups: ['group-1'] }) };
      if (url.includes('/groups/user-1/group-1')) return { ok: true, json: async () => ({ group: { title: 'Should Not Be Seen' } }) };
      return { ok: false, status: 404, json: async () => ({}) };
    });
    await act(async () => { await result.current.loadGroups(); });

    expect(countCalls(global.fetch, '/groups/user-1/group-1')).toBe(0);
    expect(result.current.groups).toEqual([{ id: 'group-1', title: 'First Title' }]);
  });

  test('a genuinely new group id is still fetched fresh even when another group id is already cached', async () => {
    let groupIds = ['group-1'];
    global.fetch = vi.fn(async (url) => {
      if (url.includes('/user/user-1')) return { ok: true, json: async () => ({ groups: groupIds }) };
      if (url.includes('/groups/user-1/group-1')) return { ok: true, json: async () => ({ group: { title: 'Group One' } }) };
      if (url.includes('/groups/user-1/group-2')) return { ok: true, json: async () => ({ group: { title: 'Group Two' } }) };
      return { ok: false, status: 404, json: async () => ({}) };
    });
    const { result } = renderHook(() => useNotes({ user: USER }));

    await act(async () => { await result.current.loadGroups(); });
    expect(countCalls(global.fetch, '/groups/user-1/group-1')).toBe(1);

    groupIds = ['group-1', 'group-2'];
    await act(async () => { await result.current.loadGroups(); });

    // cached group-1 must not be re-fetched; new group-2 must still be fetched.
    expect(countCalls(global.fetch, '/groups/user-1/group-1')).toBe(1);
    expect(countCalls(global.fetch, '/groups/user-1/group-2')).toBe(1);
    expect(result.current.groups.sort((a, b) => a.id.localeCompare(b.id))).toEqual([
      { id: 'group-1', title: 'Group One' },
      { id: 'group-2', title: 'Group Two' },
    ]);
  });
});
