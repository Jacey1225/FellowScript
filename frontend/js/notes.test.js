// Regression test for task 20260824-web-notes-stale-bundle.
//
// The legacy vanilla-JS notes sidebar (this file, used by reader.html/index.html
// non-React pages) unwraps the same backend envelope as the React hook
// (src/hooks/useNotes.js), but had zero test coverage of its own -- the bug
// report ("shows a user none of the notes they actually have") was a UI
// symptom, and useNotes.test.js only proves the *data* unwrap, not that the
// DOM actually ends up populated. This test drives notes.js's real
// loadNotes()/renderAllLists() against a mocked {notes, next_cursor_created_at,
// next_cursor_id, has_more} envelope (the current backend shape, confirmed by
// the frontend gate to be what current source already handles) and asserts
// the rendered note list actually contains the user's notes -- the same
// end-to-end path a stale/reverted bundle would break.
//
// Run with: cd frontend && npm test -- --run js/notes.test.js
import { describe, test, expect, vi, beforeEach } from 'vitest';

const USER = { user_id: 'user-1', username: 'tester' };

// notes.js and its transitive imports (bible.js, highlights.js, messaging.js)
// all read document.getElementById(...) at module scope. Provide every id
// they touch so import doesn't blow up, mirroring the real reader.html shell.
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

async function importFreshNotesModule() {
  vi.resetModules();
  mountShell();
  sessionStorage.setItem('user', JSON.stringify(USER));
  return await import('./notes.js');
}

beforeEach(() => {
  global.fetch = vi.fn();
  sessionStorage.clear();
  localStorage.clear();
});

describe('notes.js loadNotes — unwraps the keyset-paginated envelope end-to-end', () => {
  test('a user with existing notes sees them rendered, not an empty sidebar', async () => {
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        notes: {
          'note-1': { title: 'Morning reflection', text: 'body a', public: false, group_id: '', verses: [[], []] },
          'note-2': { title: 'Psalm 23 thoughts',   text: 'body b', public: true,  group_id: '', verses: [[], []] },
        },
        next_cursor_created_at: '2026-08-17T00:00:00Z',
        next_cursor_id: 'note-2',
        has_more: true,
      }),
    });

    const mod = await importFreshNotesModule();
    await mod.loadNotes();

    // Data unwrap: allNotes is payload.notes, not the raw envelope. Re-import
    // (same specifier, no reset in between) to read the live-updated binding.
    const modAfter = await import('./notes.js');
    expect(Object.keys(modAfter.allNotes).sort()).toEqual(['note-1', 'note-2']);
    expect(mod.allNotes).not.toHaveProperty('next_cursor_created_at');
    expect(mod.allNotes).not.toHaveProperty('has_more');

    // UI symptom check: the reported bug was "shows a user none of the notes
    // they actually have" -- so assert the DOM list itself was populated,
    // not just the in-memory dict.
    const listEl = document.getElementById('list-verse');
    expect(listEl.querySelectorAll('.note-card').length).toBe(2);
    expect(listEl.textContent).toContain('Morning reflection');
    expect(listEl.textContent).toContain('Psalm 23 thoughts');
    expect(listEl.textContent).not.toContain('No notes yet.');
  });

  test('a genuinely empty first page renders the empty state, not a crash', async () => {
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({ notes: {}, next_cursor_created_at: null, next_cursor_id: null, has_more: false }),
    });

    const { loadNotes } = await importFreshNotesModule();
    await loadNotes();

    const listEl = document.getElementById('list-verse');
    expect(listEl.querySelectorAll('.note-card').length).toBe(0);
    expect(listEl.textContent).toContain('No notes yet.');
  });

  test('envelope cursor fields never leak into the rendered list as fake notes', async () => {
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        notes: { 'note-1': { title: 'Only real note', text: 'x', public: false, group_id: '', verses: [[], []] } },
        next_cursor_created_at: '2026-08-17T00:00:00Z',
        next_cursor_id: 'note-1',
        has_more: true,
      }),
    });

    const { loadNotes } = await importFreshNotesModule();
    await loadNotes();

    const listEl = document.getElementById('list-verse');
    // If notes.js regressed to treating the whole payload as the notes dict
    // (the pre-pagination shape), the envelope keys would render as bogus
    // note cards alongside the real one.
    expect(listEl.querySelectorAll('.note-card').length).toBe(1);
    expect(listEl.textContent).not.toContain('next_cursor_created_at');
    expect(listEl.textContent).not.toContain('has_more');
  });

  test('a response missing .notes entirely renders the empty state, not 4 fake "Untitled" cards', async () => {
    // Reproduces the exact reported screenshot shape: a payload whose
    // top-level keys (none literally "notes") would, under the pre-8710a27a
    // bug, each have been drawn as an empty "Untitled" card grouped under
    // "General". The defensive unwrapNotesEnvelope guard must treat this as
    // "no notes" instead.
    global.fetch.mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        next_cursor_created_at: '2026-08-17T00:00:00Z',
        next_cursor_id: 'note-2',
        has_more: true,
        extra_unexpected_key: true,
      }),
    });

    const { loadNotes } = await importFreshNotesModule();
    await loadNotes();

    const listEl = document.getElementById('list-verse');
    expect(listEl.querySelectorAll('.note-card').length).toBe(0);
    expect(listEl.textContent).toContain('No notes yet.');
    expect(listEl.textContent).not.toContain('Untitled');
  });
});
