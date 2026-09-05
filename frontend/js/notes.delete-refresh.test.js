// Regression tests for task 20260904-compliance-reliability-bugs's fixes to
// the legacy vanilla-JS notes sidebar's deleteNote (frontend/js/notes.js):
//
//  - group-note-delete-list-refresh: the backend's own GET /notes/{user_id}
//    filters group_id IS NULL, so a group note is never present in allNotes
//    to begin with -- the old `deletedGroupId = allNotes[id]?.group_id`
//    lookup always missed and _loadGroupNotes() never ran after a group
//    note's delete. This falls back to the currently selected group
//    (currentGroupId) when the note is instead found in groupNotes.
//  - legacy deleteNote status check: a failed DELETE (expired session, 403,
//    500...) must not be treated as a successful one -- the note must stay
//    in allNotes and the user must see an alert, not have it silently
//    vanish from the sidebar.
//
// Deliberately does NOT call localStorage.clear() in beforeEach (unlike the
// sibling notes.test.js) -- config.js's `user` binding only reads
// sessionStorage (never touches localStorage once sessionStorage has a
// 'user' key), and this repo's jsdom/vitest environment currently has a
// pre-existing, unrelated bug where the global `localStorage` is undefined
// (Node's own experimental global shadowing jsdom's), which breaks any test
// that calls it. Avoiding it here keeps these tests independent of that
// unrelated environment issue.
//
// Run with: cd frontend && npm test -- --run js/notes.delete-refresh.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';

const USER = { user_id: 'user-1', username: 'tester' };

// notes.js and its transitive imports (bible.js, highlights.js, messaging.js)
// all read document.getElementById(...) at module scope -- provide every id
// they touch so import doesn't blow up, mirroring the real reader.html shell
// (same list as notes.test.js).
const REQUIRED_IDS = [
  'notes-sidebar', 'sidebar-toggle', 'new-note-btn', 'note-form',
  'note-form-title', 'nf-save', 'nf-cancel', 'group-sel', 'note-detail',
  'notes-main', 'note-detail-title', 'note-detail-body',
  'list-verse', 'list-public',
  'book-sel', 'ch-sel', 'vs-sel', 'state-loading', 'state-welcome',
  'chapter-card', 'card-book-label', 'card-title', 'card-section-head',
  'card-body', 'card-loc', 'prev-btn', 'next-btn', 'hl-picker',
  'msg-sidebar', 'msg-toggle', 'msg-contacts', 'msg-chat', 'msg-chat-name',
  'msg-messages', 'msg-group-info', 'msg-group-members', 'msg-input',
  'msg-send', 'msg-back', 'msg-add-friend-btn', 'msg-add-friend-form',
  'msg-add-friend-input', 'msg-add-friend-submit', 'msg-new-group-btn',
  'msg-group-form', 'msg-group-title', 'msg-member-list', 'msg-group-submit',
  'msg-group-cancel',
];

function mountShell() {
  document.body.innerHTML = REQUIRED_IDS.map(id => `<div id="${id}"></div>`).join('');
}

async function importFreshModules() {
  vi.resetModules();
  mountShell();
  sessionStorage.setItem('user', JSON.stringify(USER));
  const notesModule      = await import('./notes.js');
  const highlightsModule = await import('./highlights.js');
  return { notesModule, highlightsModule };
}

beforeEach(() => {
  global.fetch = vi.fn();
});

afterEach(() => {
  vi.restoreAllMocks();
  sessionStorage.clear();
});

describe('notes.js deleteNote — group note delete refreshes the group list', () => {
  test('a note that only lives in groupNotes (never in allNotes, matching the backend group_id IS NULL filter) still triggers a group refresh, keyed off the currently selected group', async () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    const { notesModule, highlightsModule } = await importFreshModules();
    highlightsModule.setCurrentGroupId('group-abc');
    highlightsModule.setGroupNotes({
      alice: { 'note-1': { title: 'Group note', text: 'x', group_id: 'group-abc' } },
    });

    global.fetch
      .mockResolvedValueOnce({ ok: true, status: 204, json: async () => ({}) }) // DELETE /notes/...
      .mockResolvedValueOnce({ // _loadGroupNotes refetch
        ok: true,
        json: async () => ({ notes: {}, next_cursor_created_at: null, next_cursor_id: null, has_more: false }),
      });

    await notesModule.deleteNote('note-1');

    expect(global.fetch).toHaveBeenCalledTimes(2);
    expect(global.fetch.mock.calls[0][0]).toContain('/notes/user-1');
    expect(global.fetch.mock.calls[1][0]).toContain('/groups/user-1/group-abc/notes');
  });

  test('deleting a personal note (present in allNotes, no group_id) does not trigger any group refresh', async () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    const { notesModule } = await importFreshModules();
    notesModule.allNotes['note-2'] = { title: 'Personal', text: 'y', group_id: '' };

    global.fetch.mockResolvedValueOnce({ ok: true, status: 204, json: async () => ({}) });

    await notesModule.deleteNote('note-2');

    expect(global.fetch).toHaveBeenCalledTimes(1); // only the DELETE -- no group refetch
    expect(notesModule.allNotes['note-2']).toBeUndefined();
  });
});

describe('notes.js deleteNote — a failed delete must not be treated as a success', () => {
  test('a non-ok response (500) leaves the note in allNotes and surfaces an alert instead of silently removing it', async () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    const alertSpy = vi.spyOn(window, 'alert').mockImplementation(() => {});
    const { notesModule } = await importFreshModules();
    notesModule.allNotes['note-3'] = { title: 'Still here', text: 'z', group_id: '' };

    global.fetch.mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) });

    await notesModule.deleteNote('note-3');

    expect(alertSpy).toHaveBeenCalled();
    expect(notesModule.allNotes['note-3']).toBeDefined(); // must NOT have been deleted client-side
    expect(global.fetch).toHaveBeenCalledTimes(1); // no group-refresh attempted after a failed delete
  });

  test('a network-throwing delete also surfaces an alert without removing the note', async () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    const alertSpy = vi.spyOn(window, 'alert').mockImplementation(() => {});
    const { notesModule } = await importFreshModules();
    notesModule.allNotes['note-4'] = { title: 'Still here too', text: 'z', group_id: '' };

    global.fetch.mockRejectedValueOnce(new Error('network down'));

    await notesModule.deleteNote('note-4');

    expect(alertSpy).toHaveBeenCalled();
    expect(notesModule.allNotes['note-4']).toBeDefined();
  });

  test('a failed group-note delete (500) does not attempt a group refresh either', async () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    vi.spyOn(window, 'alert').mockImplementation(() => {});
    const { notesModule, highlightsModule } = await importFreshModules();
    highlightsModule.setCurrentGroupId('group-abc');
    highlightsModule.setGroupNotes({
      alice: { 'note-5': { title: 'Group note', text: 'x', group_id: 'group-abc' } },
    });

    global.fetch.mockResolvedValueOnce({ ok: false, status: 403, json: async () => ({}) });

    await notesModule.deleteNote('note-5');

    expect(global.fetch).toHaveBeenCalledTimes(1); // DELETE only -- no group refetch on failure
  });
});
