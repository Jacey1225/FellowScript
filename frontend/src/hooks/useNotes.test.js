// Regression test for task 20260817-notes-pagination-backend: GET
// /notes/{userId} and GET /{userId}/{groupId}/notes now return one
// keyset-paginated page as {notes, next_cursor_created_at, next_cursor_id,
// has_more} instead of a bare {note_id: note} / {username: {note_id: note}}
// dict. useNotes.js was updated to unwrap payload.notes so every existing
// consumer of allNotes/groupNotes keeps working unchanged against the new
// envelope. This proves that unwrap, and guards against a regression to the
// old "the whole payload IS the notes dict" assumption (which would have
// made allNotes contain {notes: {...}, next_cursor_created_at: ..., ...} as
// if each of those were note ids).
//
// Run with: cd frontend && npm test -- --run src/hooks/useNotes.test.js
import { describe, test, expect, vi, beforeEach } from 'vitest';
import { renderHook, act, waitFor } from '@testing-library/react';
import { useNotes } from './useNotes.js';

const USER = { user_id: 'user-1', username: 'tester' };

beforeEach(() => {
  global.fetch = vi.fn();
});

describe('useNotes.loadNotes — unwraps the keyset-paginated envelope', () => {
  test('allNotes becomes payload.notes, not the whole envelope', async () => {
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        notes: {
          'note-1': { title: 'A', text: 'body a', public: false, user_id: 'user-1' },
          'note-2': { title: 'B', text: 'body b', public: true, user_id: 'user-1' },
        },
        next_cursor_created_at: '2026-08-17T00:00:00Z',
        next_cursor_id: 'note-2',
        has_more: true,
      }),
    });

    const { result } = renderHook(() => useNotes({ user: USER }));
    await act(async () => { await result.current.loadNotes(); });

    await waitFor(() => {
      expect(Object.keys(result.current.allNotes).sort()).toEqual(['note-1', 'note-2']);
    });
    expect(result.current.allNotes['note-1'].title).toBe('A');
    // Envelope keys must NOT leak into allNotes as if they were note ids.
    expect(result.current.allNotes).not.toHaveProperty('next_cursor_created_at');
    expect(result.current.allNotes).not.toHaveProperty('has_more');
  });

  test('an empty first page (no notes yet) still becomes an empty object, not a crash', async () => {
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({ notes: {}, next_cursor_created_at: null, next_cursor_id: null, has_more: false }),
    });

    const { result } = renderHook(() => useNotes({ user: USER }));
    await act(async () => { await result.current.loadNotes(); });

    await waitFor(() => expect(result.current.allNotes).toEqual({}));
  });
});

describe('useNotes.loadGroupNotes — unwraps the keyset-paginated envelope', () => {
  test('groupNotes becomes payload.notes (username -> {note_id: note}), not the whole envelope', async () => {
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        notes: {
          alice: { 'note-1': { title: 'Shared', text: 'x', public: true, user_id: 'user-2' } },
        },
        next_cursor_created_at: null,
        next_cursor_id: null,
        has_more: false,
      }),
    });

    const { result } = renderHook(() => useNotes({ user: USER }));
    await act(async () => { await result.current.loadGroupNotes('group-abc'); });

    await waitFor(() => {
      expect(Object.keys(result.current.groupNotes)).toEqual(['alice']);
    });
    expect(result.current.groupNotes.alice['note-1'].title).toBe('Shared');
    expect(result.current.groupNotes).not.toHaveProperty('has_more');
  });
});
