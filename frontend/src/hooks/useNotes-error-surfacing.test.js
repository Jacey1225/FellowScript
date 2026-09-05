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
  // Updated by task 20260904-compliance-performance-fixes (testing gate,
  // optimization #4): applyFilter's sort path used to round-trip through
  // POST /sort/ purely to re-derive a predicate over data already in memory
  // client-side -- that round trip is now gone, replaced by
  // localSortNotesByDate acting directly on the normalized in-memory notes.
  // The behavior this test actually cares about (normalizeNote's `verses`
  // default is [[], []] for every note applyFilter touches, not a bare `[]`)
  // is unchanged, so this now asserts directly on the resulting
  // `filteredNotes` shape instead of inspecting an outgoing /sort/ payload
  // that no longer exists for this path.
  test('a note missing verses entirely normalizes to [[], []] in applyFilter\'s local sort result', async () => {
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

    // applyFilter (sort-only, no filter) is synchronous now -- no network
    // call for this path at all -- so no fetch mock needs queuing here.
    await act(async () => {
      result.current.applyFilter({ sortVal: 'desc', filterType: null, filterVal: null, activeTab: 'personal' });
    });

    await waitFor(() => expect(result.current.filteredNotes).not.toBeNull());
    expect(result.current.filteredNotes['note-1'].verses).toEqual([[], []]);
  });
});
