// Regression tests for task 20260904-compliance-performance-fixes, step 3
// (High H13, frontend-only fix): loadContacts() previously re-fetched every
// friend's username + message preview and every group's title/members +
// message history on EVERY call, even though ContactsPanel/MessagingSidebar
// call onLoad() again right after addFriend/removeFriend/createGroup/
// updateGroup/leaveGroup succeed — so one new friend or one edited group
// triggered a full N-fetch refetch of every already-known friend/group too.
//
// Fixed by adding friendEntryCache/groupEntryCache (keyed by id), reused on
// a repeat loadContacts() call, and invalidated in removeFriend/blockUser
// (friend) and updateGroup/leaveGroup (group) so a mutated/removed item's
// stale row can't resurface. This suite proves both halves of that
// contract through the real useMessaging() hook (not a reimplementation):
// dedup on repeat calls, and correct invalidation on each mutating action.
//
// Run with: cd frontend && npm test -- --run src/hooks/useMessaging.contactCache.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { message } from 'antd';
import { useMessaging } from './useMessaging.js';

const USER = { user_id: 'user-1', username: 'tester', friends: ['friend-1'], groups: ['group-1'] };

class MockWebSocket {
  constructor() {
    this.readyState = 0;
    this.onopen = null;
    this.onmessage = null;
    this.onerror = null;
    this.onclose = null;
  }
  close() { this.readyState = 3; }
  send() {}
}

// Counts how many times a given URL substring was fetched, without caring
// about call order relative to other endpoints.
function countCalls(fetchMock, substring) {
  return fetchMock.mock.calls.filter(([url]) => url.includes(substring)).length;
}

function mockFetchImpl({ friendsUsername = 'friend-uname', groupTitle = 'Group One' } = {}) {
  return vi.fn(async (url) => {
    if (url.includes('/user/user-1')) {
      return { ok: true, json: async () => USER };
    }
    if (url.includes('/user/friend-1')) {
      return { ok: true, json: async () => ({ username: friendsUsername }) };
    }
    if (url.includes('/message/messages/')) {
      return { ok: true, json: async () => ({ payload: { host_msgs: [], other_msgs: [] } }) };
    }
    if (url.includes('/groups/user-1/group-1')) {
      return { ok: true, json: async () => ({ group: { title: groupTitle, users: ['user-1', 'friend-2'] }, host_msgs: [], other_msgs: [] } ) };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  });
}

beforeEach(() => {
  global.WebSocket = MockWebSocket;
  vi.spyOn(message, 'error').mockImplementation(() => {});
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('useMessaging.loadContacts — friendEntryCache/groupEntryCache dedup (H13)', () => {
  test('a second loadContacts() call reuses cached friend/group rows instead of re-fetching them', async () => {
    global.fetch = mockFetchImpl();
    const { result } = renderHook(() => useMessaging({ user: USER }));

    await act(async () => { await result.current.loadContacts(); });
    const friendFetchesAfterFirst = countCalls(global.fetch, '/user/friend-1');
    const groupFetchesAfterFirst  = countCalls(global.fetch, '/groups/user-1/group-1');
    expect(friendFetchesAfterFirst).toBe(1);
    expect(groupFetchesAfterFirst).toBe(1);
    expect(result.current.friends).toEqual([
      expect.objectContaining({ id: 'friend-1', name: 'friend-uname', type: 'friend' }),
    ]);
    expect(result.current.groups['group-1']).toEqual({ title: 'Group One', users: ['user-1', 'friend-2'] });

    await act(async () => { await result.current.loadContacts(); });
    // No additional per-friend/per-group fetches on the repeat call -- the
    // whole point of this fix.
    expect(countCalls(global.fetch, '/user/friend-1')).toBe(friendFetchesAfterFirst);
    expect(countCalls(global.fetch, '/groups/user-1/group-1')).toBe(groupFetchesAfterFirst);
    // The cached row is still surfaced correctly, not dropped/emptied.
    expect(result.current.friends).toEqual([
      expect.objectContaining({ id: 'friend-1', name: 'friend-uname', type: 'friend' }),
    ]);
    expect(result.current.groups['group-1']).toEqual({ title: 'Group One', users: ['user-1', 'friend-2'] });
  });

  test('a genuinely new friend id (never cached) is still fetched fresh alongside an already-cached one', async () => {
    const twoFriendUser = { ...USER, friends: ['friend-1'], groups: [] };
    global.fetch = vi.fn(async (url) => {
      if (url.includes('/user/user-1')) return { ok: true, json: async () => twoFriendUser };
      if (url.includes('/user/friend-1')) return { ok: true, json: async () => ({ username: 'first-friend' }) };
      if (url.includes('/user/friend-2')) return { ok: true, json: async () => ({ username: 'second-friend' }) };
      if (url.includes('/message/messages/')) return { ok: true, json: async () => ({ payload: { host_msgs: [], other_msgs: [] } }) };
      return { ok: false, status: 404, json: async () => ({}) };
    });
    const { result, rerender } = renderHook(({ user }) => useMessaging({ user }), { initialProps: { user: twoFriendUser } });

    await act(async () => { await result.current.loadContacts(); });
    expect(countCalls(global.fetch, '/user/friend-1')).toBe(1);
    expect(result.current.friends.map(f => f.id)).toEqual(['friend-1']);

    // Simulate addFriend succeeding and a new friend id showing up.
    twoFriendUser.friends = ['friend-1', 'friend-2'];
    rerender({ user: twoFriendUser });
    await act(async () => { await result.current.loadContacts(); });

    // friend-1 (cached) must not be re-fetched; friend-2 (new) must be.
    expect(countCalls(global.fetch, '/user/friend-1')).toBe(1);
    expect(countCalls(global.fetch, '/user/friend-2')).toBe(1);
    expect(result.current.friends.map(f => f.id).sort()).toEqual(['friend-1', 'friend-2']);
  });
});

describe('useMessaging cache invalidation — removeFriend/blockUser/updateGroup/leaveGroup (H13)', () => {
  test('removeFriend invalidates the cached friend row so a later re-add re-fetches fresh data', async () => {
    global.fetch = mockFetchImpl({ friendsUsername: 'old-name' });
    const { result } = renderHook(() => useMessaging({ user: USER }));
    await act(async () => { await result.current.loadContacts(); });
    expect(countCalls(global.fetch, '/user/friend-1')).toBe(1);

    global.fetch.mockImplementationOnce(async () => ({ ok: true, status: 204, json: async () => ({}) }));
    await act(async () => { await result.current.removeFriend('friend-1'); });

    // Change the mocked username so a stale cache entry would be detectable.
    global.fetch = mockFetchImpl({ friendsUsername: 'renamed-friend' });
    await act(async () => { await result.current.loadContacts(); });

    expect(countCalls(global.fetch, '/user/friend-1')).toBe(1);
    expect(result.current.friends).toEqual([
      expect.objectContaining({ id: 'friend-1', name: 'renamed-friend' }),
    ]);
  });

  test('blockUser invalidates the cached friend row the same way removeFriend does', async () => {
    global.fetch = mockFetchImpl({ friendsUsername: 'old-name' });
    const { result } = renderHook(() => useMessaging({ user: USER }));
    await act(async () => { await result.current.loadContacts(); });

    global.fetch.mockImplementationOnce(async () => ({ ok: true, status: 200, json: async () => ({}) }));
    await act(async () => { await result.current.blockUser('friend-1'); });

    global.fetch = mockFetchImpl({ friendsUsername: 'renamed-after-block' });
    await act(async () => { await result.current.loadContacts(); });

    expect(countCalls(global.fetch, '/user/friend-1')).toBe(1);
    expect(result.current.friends).toEqual([
      expect.objectContaining({ id: 'friend-1', name: 'renamed-after-block' }),
    ]);
  });

  test('updateGroup invalidates the cached group row so the next loadContacts sees the new title/members', async () => {
    global.fetch = mockFetchImpl({ groupTitle: 'Old Title' });
    const { result } = renderHook(() => useMessaging({ user: USER }));
    await act(async () => { await result.current.loadContacts(); });
    expect(result.current.groups['group-1'].title).toBe('Old Title');

    global.fetch.mockImplementationOnce(async () => ({ ok: true, status: 204, json: async () => ({}) }));
    await act(async () => { await result.current.updateGroup('group-1', 'New Title', ['friend-2']); });

    global.fetch = mockFetchImpl({ groupTitle: 'Freshly Fetched Title' });
    await act(async () => { await result.current.loadContacts(); });

    expect(countCalls(global.fetch, '/groups/user-1/group-1')).toBe(1);
    expect(result.current.groups['group-1'].title).toBe('Freshly Fetched Title');
  });

  test('leaveGroup invalidates the cached group row', async () => {
    global.fetch = mockFetchImpl({ groupTitle: 'Original Title' });
    const { result } = renderHook(() => useMessaging({ user: USER }));
    await act(async () => { await result.current.loadContacts(); });

    global.fetch.mockImplementationOnce(async () => ({ ok: true, status: 204, json: async () => ({}) }));
    await act(async () => { await result.current.leaveGroup('group-1'); });

    global.fetch = mockFetchImpl({ groupTitle: 'Rejoined With New Title' });
    await act(async () => { await result.current.loadContacts(); });

    expect(countCalls(global.fetch, '/groups/user-1/group-1')).toBe(1);
    expect(result.current.groups['group-1'].title).toBe('Rejoined With New Title');
  });
});
