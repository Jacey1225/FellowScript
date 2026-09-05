// Regression tests for task 20260904-compliance-performance-fixes, step 3
// (Medium optimization #4): applyFilter used to round-trip already-in-memory
// notes through POST /filter/ and POST /sort/ purely to re-derive the same
// predicate the backend already applies to data the client already had.
// applyFilter now filters/sorts locally via localFilterNotes/
// localSortNotesByDate, which must match api/backend/filters/filter_notes.py's
// Filters/Sorting classes exactly:
//   - book:  case-insensitive substring match against verses[i][0]
//   - date:  exact match on timestamp[:10]
//   - user:  exact membership in the filter's user list
//   - title: case-insensitive substring match against note.title
//   - sort:  stable sort by parsed timestamp, `descending` flag, with an
//            unparseable timestamp sorting as the oldest possible value
//     (mirrors the backend's datetime.min fallback).
//
// This suite drives the real applyFilter() through the real useNotes() hook
// (not a reimplementation of the algorithm) and asserts no network call is
// ever made for this path anymore.
//
// Run with: cd frontend && npm test -- --run src/hooks/useNotes.localFilterSort.test.js
import { describe, test, expect, vi, beforeEach } from 'vitest';
import { renderHook, act, waitFor } from '@testing-library/react';
import { message } from 'antd';
import { useNotes } from './useNotes.js';

const USER = { user_id: 'user-1', username: 'tester' };

function seedNote(id, overrides = {}) {
  return {
    title: '', text: '', public: false, group_id: '', verses: [[], []],
    replies: [], is_reply: false, timestamp: '2026-01-01 00:00:00.000000', user: '',
    ...overrides,
  };
}

async function loadNotesFixture(result, notesById) {
  global.fetch.mockResolvedValueOnce({
    ok: true,
    json: async () => ({ notes: notesById, next_cursor_created_at: null, next_cursor_id: null, has_more: false }),
  });
  await act(async () => { await result.current.loadNotes(); });
}

beforeEach(() => {
  global.fetch = vi.fn();
  vi.spyOn(message, 'error').mockImplementation(() => {});
  vi.spyOn(message, 'warning').mockImplementation(() => {});
});

describe('useNotes.applyFilter — local filter/sort matches backend semantics, no network round trip (optimization #4)', () => {
  test('book filter: case-insensitive substring match against verses[i][0], and never fetches /filter/ or /sort/', async () => {
    const { result } = renderHook(() => useNotes({ user: USER }));
    await loadNotesFixture(result, {
      'n1': seedNote('n1', { verses: [['Genesis', 1, 1], []] }),
      'n2': seedNote('n2', { verses: [['genesis', 2, 1], []] }), // different case
      'n3': seedNote('n3', { verses: [['Exodus', 1, 1], []] }),
    });

    const fetchCallsBefore = global.fetch.mock.calls.length;
    act(() => {
      result.current.applyFilter({ sortVal: '', filterType: 'book', filterVal: 'gen', activeTab: 'personal' });
    });
    await waitFor(() => expect(result.current.filteredNotes).not.toBeNull());

    expect(Object.keys(result.current.filteredNotes).sort()).toEqual(['n1', 'n2']);
    expect(global.fetch.mock.calls.length).toBe(fetchCallsBefore);
    expect(global.fetch.mock.calls.some(([url]) => url.includes('/filter/') || url.includes('/sort/'))).toBe(false);
  });

  test('date filter: exact match on the first 10 characters of the timestamp', async () => {
    const { result } = renderHook(() => useNotes({ user: USER }));
    await loadNotesFixture(result, {
      'n1': seedNote('n1', { timestamp: '2026-03-01 08:00:00.000000' }),
      'n2': seedNote('n2', { timestamp: '2026-03-01 23:59:59.000000' }),
      'n3': seedNote('n3', { timestamp: '2026-03-02 08:00:00.000000' }),
    });

    act(() => {
      result.current.applyFilter({ sortVal: '', filterType: 'date', filterVal: '2026-03-01', activeTab: 'personal' });
    });
    await waitFor(() => expect(result.current.filteredNotes).not.toBeNull());

    expect(Object.keys(result.current.filteredNotes).sort()).toEqual(['n1', 'n2']);
  });

  test('user filter (group tab): exact membership match against the group\'s per-username notes, not substring', async () => {
    // normalizeNote always stamps the personal-tab path's `user` field with
    // the current user's own username (these are all the signed-in user's
    // own notes) -- a per-note `user` filter is only meaningful on the group
    // tab, where the payload is keyed by each member's own username. Set
    // that up via the real selectGroup()/loadGroupNotes() flow.
    const { result } = renderHook(() => useNotes({ user: USER }));
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        notes: {
          alice:   { 'n1': seedNote('n1') },
          alicia:  { 'n2': seedNote('n2') }, // must NOT match a substring filter on "alice"
        },
        next_cursor_created_at: null, next_cursor_id: null, has_more: false,
      }),
    });
    await act(async () => { await result.current.selectGroup('group-abc'); });
    await waitFor(() => expect(result.current.groupNotes.alice).toBeDefined());

    act(() => {
      result.current.applyFilter({ sortVal: '', filterType: 'user', filterVal: 'alice', activeTab: 'public' });
    });
    await waitFor(() => expect(result.current.filteredGroup).not.toBeNull());

    expect(Object.keys(result.current.filteredGroup)).toEqual(['alice']);
    expect(Object.keys(result.current.filteredGroup.alice)).toEqual(['n1']);
  });

  test('title filter: case-insensitive substring match', async () => {
    const { result } = renderHook(() => useNotes({ user: USER }));
    await loadNotesFixture(result, {
      'n1': seedNote('n1', { title: 'On Faith and Hope' }),
      'n2': seedNote('n2', { title: 'FAITHFUL steps' }),
      'n3': seedNote('n3', { title: 'Unrelated' }),
    });

    act(() => {
      result.current.applyFilter({ sortVal: '', filterType: 'title', filterVal: 'faith', activeTab: 'personal' });
    });
    await waitFor(() => expect(result.current.filteredNotes).not.toBeNull());

    expect(Object.keys(result.current.filteredNotes).sort()).toEqual(['n1', 'n2']);
  });

  test('sort desc: newest first, matching Sorting.sort_date(descending=True)', async () => {
    const { result } = renderHook(() => useNotes({ user: USER }));
    await loadNotesFixture(result, {
      'n1': seedNote('n1', { timestamp: '2026-01-01 00:00:00.000000' }),
      'n2': seedNote('n2', { timestamp: '2026-03-01 00:00:00.000000' }),
      'n3': seedNote('n3', { timestamp: '2026-02-01 00:00:00.000000' }),
    });

    act(() => {
      result.current.applyFilter({ sortVal: 'desc', filterType: null, filterVal: null, activeTab: 'personal' });
    });
    await waitFor(() => expect(result.current.filteredNotes).not.toBeNull());

    expect(Object.keys(result.current.filteredNotes)).toEqual(['n2', 'n3', 'n1']);
  });

  test('sort asc: oldest first', async () => {
    const { result } = renderHook(() => useNotes({ user: USER }));
    await loadNotesFixture(result, {
      'n1': seedNote('n1', { timestamp: '2026-01-01 00:00:00.000000' }),
      'n2': seedNote('n2', { timestamp: '2026-03-01 00:00:00.000000' }),
    });

    act(() => {
      result.current.applyFilter({ sortVal: 'asc', filterType: null, filterVal: null, activeTab: 'personal' });
    });
    await waitFor(() => expect(result.current.filteredNotes).not.toBeNull());

    expect(Object.keys(result.current.filteredNotes)).toEqual(['n1', 'n2']);
  });

  test('an unparseable timestamp sorts as the oldest possible value (matches backend datetime.min fallback)', async () => {
    const { result } = renderHook(() => useNotes({ user: USER }));
    await loadNotesFixture(result, {
      'good':    seedNote('good', { timestamp: '2026-01-01 00:00:00.000000' }),
      'garbled': seedNote('garbled', { timestamp: 'not-a-real-timestamp' }),
    });

    act(() => {
      result.current.applyFilter({ sortVal: 'desc', filterType: null, filterVal: null, activeTab: 'personal' });
    });
    await waitFor(() => expect(result.current.filteredNotes).not.toBeNull());

    // Descending (newest first): the unparseable note must sink to the end,
    // not sort first/NaN-adjacent or throw.
    expect(Object.keys(result.current.filteredNotes)).toEqual(['good', 'garbled']);
  });

  test('combined filter + sort applies the filter before sorting, matching the backend pipeline order', async () => {
    const { result } = renderHook(() => useNotes({ user: USER }));
    await loadNotesFixture(result, {
      'n1': seedNote('n1', { title: 'Reflection', timestamp: '2026-01-01 00:00:00.000000' }),
      'n2': seedNote('n2', { title: 'Reflection deux', timestamp: '2026-03-01 00:00:00.000000' }),
      'n3': seedNote('n3', { title: 'Unrelated', timestamp: '2026-05-01 00:00:00.000000' }),
    });

    act(() => {
      result.current.applyFilter({ sortVal: 'desc', filterType: 'title', filterVal: 'reflection', activeTab: 'personal' });
    });
    await waitFor(() => expect(result.current.filteredNotes).not.toBeNull());

    expect(Object.keys(result.current.filteredNotes)).toEqual(['n2', 'n1']);
  });

  test('clearFilter resets back to unfiltered (filteredNotes null)', async () => {
    const { result } = renderHook(() => useNotes({ user: USER }));
    await loadNotesFixture(result, { 'n1': seedNote('n1', { title: 'Hello' }) });

    act(() => {
      result.current.applyFilter({ sortVal: '', filterType: 'title', filterVal: 'hello', activeTab: 'personal' });
    });
    await waitFor(() => expect(result.current.filteredNotes).not.toBeNull());

    act(() => { result.current.clearFilter(); });
    expect(result.current.filteredNotes).toBeNull();
    expect(result.current.filterActive).toBe(false);
  });
});
