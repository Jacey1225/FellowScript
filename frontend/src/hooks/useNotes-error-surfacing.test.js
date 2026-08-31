// Regression tests for the 20260830-compliance-remediation task's frontend
// fixes to useNotes.js:
//
//   dependency-errors #4 (React stack only) — saveNote/deleteNote must
//   surface a visible antd `message.error` on a caught network failure
//   (fetch throwing) instead of a silent no-op, mirroring useMessaging.js's
//   equivalent fix.
//
//   logic-errors #2 — normalizeNote's `verses` default must be `[[], []]`
//   (matching frontend/js/notes.js's legacy-stack default), not a bare `[]`
//   that would make single-verse-array consumers (getVerse/verseRefLabel)
//   crash or silently render nothing on a note with no verses.
//
// Run with: cd frontend && npm test -- --run src/hooks/useNotes-error-surfacing.test.js
import { describe, test, expect, vi, beforeEach } from 'vitest';
import { renderHook, act, waitFor } from '@testing-library/react';
import { message } from 'antd';
import { useNotes } from './useNotes.js';

const USER = { user_id: 'user-1', username: 'tester' };

beforeEach(() => {
  global.fetch = vi.fn();
  vi.spyOn(message, 'error').mockImplementation(() => {});
});

describe('useNotes.saveNote — surfaces a visible error on fetch failure (dependency-errors #4)', () => {
  test('a rejected fetch (network failure) surfaces message.error, not a silent false', async () => {
    global.fetch.mockRejectedValueOnce(new Error('network down'));
    const { result } = renderHook(() => useNotes({ user: USER }));

    let ok;
    await act(async () => {
      ok = await result.current.saveNote({ title: 'T', text: 'B', verses: [[], []] }, null);
    });

    expect(ok).toBe(false);
    expect(message.error).toHaveBeenCalled();
  });
});

describe('useNotes.deleteNote — surfaces a visible error on fetch failure (dependency-errors #4)', () => {
  test('a rejected fetch surfaces message.error', async () => {
    global.fetch.mockRejectedValueOnce(new Error('network down'));
    const { result } = renderHook(() => useNotes({ user: USER }));

    await act(async () => { await result.current.deleteNote('note-1'); });

    expect(message.error).toHaveBeenCalled();
  });

  test('a non-ok response (e.g. 500) also surfaces message.error, not just thrown exceptions', async () => {
    global.fetch.mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) });
    const { result } = renderHook(() => useNotes({ user: USER }));

    await act(async () => { await result.current.deleteNote('note-1'); });

    expect(message.error).toHaveBeenCalled();
  });
});

describe('useNotes filter/sort payload — verses default is [[], []] (logic-errors #2)', () => {
  test('a note missing verses entirely normalizes to [[], []] when applyFilter builds its payload', async () => {
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        notes: { 'note-1': { title: 'No verses', text: 'body', public: false } }, // verses omitted
        next_cursor_created_at: null, next_cursor_id: null, has_more: false,
      }),
    });
    const { result } = renderHook(() => useNotes({ user: USER }));
    await act(async () => { await result.current.loadNotes(); });
    await waitFor(() => expect(result.current.allNotes['note-1']).toBeDefined());

    // applyFilter with only a sort (no server-side filter round trip needed
    // to inspect the outgoing payload) still normalizes every note through
    // normalizeNote before sending it anywhere -- capture what /sort/ was
    // called with to inspect the normalized verses shape.
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({ 'note-1': { title: 'No verses', text: 'body', verses: [[], []] } }),
    });
    await act(async () => {
      await result.current.applyFilter({ sortVal: 'desc', filterType: null, filterVal: null, activeTab: 'personal' });
    });

    const sortCall = global.fetch.mock.calls.find(([url]) => url.includes('/sort/'));
    expect(sortCall).toBeDefined();
    const body = JSON.parse(sortCall[1].body);
    expect(body.notes['note-1'].verses).toEqual([[], []]);
  });
});
