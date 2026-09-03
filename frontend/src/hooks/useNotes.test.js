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

describe('useNotes.loadNotes — fails safe on a malformed/missing envelope (defensive guard)', () => {
  test('a response missing .notes entirely (e.g. a regression to the old bare {note_id: note} shape) becomes an empty allNotes, not the raw payload treated as notes', async () => {
    // This is the exact pre-8710a27a failure mode from the bug report: the
    // whole envelope (4 top-level keys) would have been assigned directly
    // as allNotes, so each key rendered as a fake "Untitled"/"General" note.
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        'note-1': { title: 'A', text: 'body a' },
        'note-2': { title: 'B', text: 'body b' },
      }),
    });

    const { result } = renderHook(() => useNotes({ user: USER }));
    await act(async () => { await result.current.loadNotes(); });

    await waitFor(() => expect(result.current.allNotes).toEqual({}));
  });

  test('a response with a non-object .notes fails safe to an empty allNotes instead of throwing or leaking garbage', async () => {
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({ notes: 'unexpected-string', next_cursor_created_at: null, next_cursor_id: null, has_more: false }),
    });

    const { result } = renderHook(() => useNotes({ user: USER }));
    await act(async () => { await result.current.loadNotes(); });

    await waitFor(() => expect(result.current.allNotes).toEqual({}));
  });
});

describe('useNotes.postReply — public defaults to false (edit-permission deny-by-default)', () => {
  // Task 20260903-notes-public-repurpose, clarification answer 7: `public`
  // now means "group members may edit," not "visible" -- a reply already
  // inherits group_id visibility, so defaulting this open is no longer
  // justified. Proves the actual request body sent to POST /notes/reply/...
  // carries public: false, not the old hardcoded true.
  test('the POST body sent for a new reply has public: false', async () => {
    // First fetch: selectGroup's loadGroupNotes call.
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({ notes: {}, next_cursor_created_at: null, next_cursor_id: null, has_more: false }),
    });
    // Second fetch: the postReply call itself.
    global.fetch.mockResolvedValueOnce({
      ok: true,
      status: 201,
      json: async () => ({ id: 'reply-1' }),
    });

    const { result } = renderHook(() => useNotes({ user: USER }));
    await act(async () => { await result.current.selectGroup('group-abc'); });
    await act(async () => { await result.current.postReply('note-1', 'a reply body'); });

    const replyCall = global.fetch.mock.calls.find(([url]) => url.includes('/notes/reply/'));
    expect(replyCall).toBeTruthy();
    const sentBody = JSON.parse(replyCall[1].body);
    expect(sentBody.public).toBe(false);
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
