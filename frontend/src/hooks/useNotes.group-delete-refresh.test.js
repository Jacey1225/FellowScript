// Regression test for task 20260904-compliance-reliability-bugs's fix to
// useNotes.js's deleteNote: the backend's own GET /notes/{user_id} filters
// group_id IS NULL, so a group note is never present in `allNotes` to begin
// with -- the old `allNotes[id]?.group_id` lookup always missed, and the
// group's note list silently never refreshed after a delete. deleteNote now
// also checks `groupNotes` (scoped to the currently selected group tab) so a
// group note found there still triggers loadGroupNotes(currentGroupId).
//
// Run with: cd frontend && npm test -- --run src/hooks/useNotes.group-delete-refresh.test.js
import { describe, test, expect, vi, beforeEach } from 'vitest';
import { renderHook, act, waitFor } from '@testing-library/react';
import { message } from 'antd';
import { useNotes } from './useNotes.js';

const USER = { user_id: 'user-1', username: 'tester' };

beforeEach(() => {
  global.fetch = vi.fn();
  vi.spyOn(message, 'error').mockImplementation(() => {});
});

describe('useNotes.deleteNote — group note delete refreshes the group list', () => {
  test('deleting a note that lives only in groupNotes (never allNotes) still refreshes the currently-selected group', async () => {
    const { result } = renderHook(() => useNotes({ user: USER }));

    // selectGroup('group-abc') -> loadGroupNotes fetch, seeding groupNotes
    // and currentGroupId exactly as the real UI flow does before a delete.
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        notes: { alice: { 'note-1': { title: 'Group note', text: 'x', group_id: 'group-abc' } } },
        next_cursor_created_at: null, next_cursor_id: null, has_more: false,
      }),
    });
    await act(async () => { await result.current.selectGroup('group-abc'); });
    await waitFor(() => expect(result.current.groupNotes.alice).toBeDefined());
    expect(result.current.allNotes['note-1']).toBeUndefined(); // confirms the group_id IS NULL filter premise

    // DELETE, then deleteNote's own loadGroupNotes('group-abc') refetch.
    global.fetch
      .mockResolvedValueOnce({ ok: true, status: 204, json: async () => ({}) })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ notes: {}, next_cursor_created_at: null, next_cursor_id: null, has_more: false }),
      });

    await act(async () => { await result.current.deleteNote('note-1'); });

    const groupRefetchCall = global.fetch.mock.calls.find(([url]) => url.includes('/groups/user-1/group-abc/notes'));
    expect(groupRefetchCall).toBeDefined();
    await waitFor(() => expect(result.current.groupNotes).toEqual({}));
  });

  test('deleting a personal note (present in allNotes, no group_id) never triggers a group refresh', async () => {
    const { result } = renderHook(() => useNotes({ user: USER }));

    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        notes: { 'note-2': { title: 'Personal', text: 'y', group_id: '' } },
        next_cursor_created_at: null, next_cursor_id: null, has_more: false,
      }),
    });
    await act(async () => { await result.current.loadNotes(); });
    await waitFor(() => expect(result.current.allNotes['note-2']).toBeDefined());

    global.fetch.mockResolvedValueOnce({ ok: true, status: 204, json: async () => ({}) });
    await act(async () => { await result.current.deleteNote('note-2'); });

    expect(global.fetch).toHaveBeenCalledTimes(2); // loadNotes + DELETE only, no group refetch
    expect(result.current.allNotes['note-2']).toBeUndefined();
  });

  test('a failed group-note delete (500) does not attempt a group refresh and keeps message.error visible', async () => {
    const { result } = renderHook(() => useNotes({ user: USER }));

    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        notes: { alice: { 'note-3': { title: 'Group note', text: 'x', group_id: 'group-abc' } } },
        next_cursor_created_at: null, next_cursor_id: null, has_more: false,
      }),
    });
    await act(async () => { await result.current.selectGroup('group-abc'); });
    await waitFor(() => expect(result.current.groupNotes.alice).toBeDefined());

    global.fetch.mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) });
    await act(async () => { await result.current.deleteNote('note-3'); });

    expect(message.error).toHaveBeenCalled();
    expect(global.fetch).toHaveBeenCalledTimes(2); // selectGroup's load + the failed DELETE only
  });
});
