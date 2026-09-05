// Regression tests for task 20260904-compliance-performance-fixes, step 3,
// covering the legacy vanilla-JS notes sidebar (frontend/js/notes.js):
//
//  - Medium optimization #4: _applyFiltersAndSort used to round-trip
//    already-in-memory notes through POST /filter/ and POST /sort/ purely
//    to re-derive the same predicate the backend already applies. It now
//    filters/sorts locally via _localFilterNotes/_localSortNotesByDate,
//    which must match api/backend/filters/filter_notes.py's Filters/Sorting
//    classes exactly (same as the React useNotes.js sibling fix).
//  - High H13: populateGroupSelector's groupTitleCache dedupes a group's
//    title fetch across repeat calls.
//
// Drives the real DOM-wired _applyFiltersAndSort (via the real #fs-apply
// click listener wired by initNotesSidebar(), same pattern as
// notes.user-filter-escaping.test.js) and the real exported
// populateGroupSelector(), rather than reimplementing either algorithm.
//
// Deliberately does NOT call localStorage.clear() in beforeEach (mirrors
// notes.delete-refresh.test.js) -- this repo's jsdom/vitest environment has
// a pre-existing, unrelated bug where the global `localStorage` is
// undefined (Node's own experimental global shadowing jsdom's).
//
// Run with: cd frontend && npm test -- --run js/notes.localFilterSort.test.js
import { describe, test, expect, vi, beforeEach } from 'vitest';

const USER = { user_id: 'user-1', username: 'tester' };

const REQUIRED_IDS = [
  'notes-sidebar', 'sidebar-toggle', 'new-note-btn', 'note-form',
  'note-form-title', 'nf-save', 'nf-cancel', 'note-detail',
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
  document.body.innerHTML =
    REQUIRED_IDS.map(id => `<div id="${id}"></div>`).join('') +
    `
    <select id="group-sel"><option value="">Personal</option></select>
    <div class="filter-panel" id="filter-panel">
      <button class="filter-back-btn" id="filter-back-btn">&#8592;</button>
      <span class="filter-active-badge" id="filter-active-badge" style="display:none">Active</span>
      <div class="filter-section">
        <label><input type="radio" name="fs-filter" value=""      checked /></label>
        <label><input type="radio" name="fs-filter" value="book"         /></label>
        <label><input type="radio" name="fs-filter" value="title"        /></label>
        <label><input type="radio" name="fs-filter" value="date"         /></label>
        <label><input type="radio" name="fs-filter" value="user"         /></label>
      </div>
      <div id="fs-input-wrap" style="display:none">
        <input id="fs-input" class="fs-value-input" type="text" />
      </div>
      <div id="fs-user-list" style="display:none" class="filter-section"></div>
      <div class="filter-section">
        <label><input type="radio" name="fs-sort" value=""     checked /></label>
        <label><input type="radio" name="fs-sort" value="desc"        /></label>
        <label><input type="radio" name="fs-sort" value="asc"         /></label>
      </div>
      <div class="filter-btns">
        <button class="form-btn save"   id="fs-apply">Apply</button>
        <button class="form-btn cancel" id="fs-clear">Clear</button>
      </div>
    </div>
    <button class="sidebar-head-filter-btn" id="sidebar-open-filter-btn"></button>
    <button class="stab active" data-tab="verse"></button>
    <button class="stab" data-tab="public"></button>
    `;
}

async function importFreshModules() {
  vi.resetModules();
  mountShell();
  sessionStorage.setItem('user', JSON.stringify(USER));
  const notes = await import('./notes.js');
  return { notes };
}

function setFilter(type, value) {
  const radio = document.querySelector(`input[name="fs-filter"][value="${type}"]`);
  radio.checked = true;
  radio.dispatchEvent(new Event('change', { bubbles: true }));
  if (type) document.getElementById('fs-input').value = value;
}

function setSort(value) {
  const radio = document.querySelector(`input[name="fs-sort"][value="${value}"]`);
  radio.checked = true;
}

function clickApply() {
  document.getElementById('fs-apply').dispatchEvent(new Event('click', { bubbles: true }));
}

function renderedIds(listId) {
  return Array.from(document.getElementById(listId).querySelectorAll('.note-card'))
    .map(el => el.id.replace(/^nc-/, ''));
}

beforeEach(() => {
  sessionStorage.clear();
});

describe('notes.js _applyFiltersAndSort — local filter/sort, no network round trip (optimization #4)', () => {
  test('book filter (case-insensitive substring) matches locally and never calls /filter/ or /sort/', async () => {
    const { notes } = await importFreshModules();
    notes.initNotesSidebar();

    global.fetch = vi.fn().mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        notes: {
          'n1': { title: 'A', text: '', public: false, group_id: '', verses: [['Genesis', 1, 1], []], timestamp: '2026-01-01 00:00:00.000000' },
          'n2': { title: 'B', text: '', public: false, group_id: '', verses: [['genesis', 2, 1], []], timestamp: '2026-01-02 00:00:00.000000' },
          'n3': { title: 'C', text: '', public: false, group_id: '', verses: [['Exodus', 1, 1], []],  timestamp: '2026-01-03 00:00:00.000000' },
        },
        next_cursor_created_at: null, next_cursor_id: null, has_more: false,
      }),
    });
    await notes.loadNotes();

    setFilter('book', 'gen');
    clickApply();

    expect(renderedIds('list-verse').sort()).toEqual(['n1', 'n2']);
    expect(global.fetch.mock.calls.some(([url]) => url.includes('/filter/') || url.includes('/sort/'))).toBe(false);
  });

  test('title filter (case-insensitive substring)', async () => {
    const { notes } = await importFreshModules();
    notes.initNotesSidebar();

    global.fetch = vi.fn().mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        notes: {
          'n1': { title: 'On Faith and Hope', text: '', public: false, group_id: '', verses: [[], []], timestamp: '2026-01-01 00:00:00.000000' },
          'n2': { title: 'FAITHFUL steps',    text: '', public: false, group_id: '', verses: [[], []], timestamp: '2026-01-02 00:00:00.000000' },
          'n3': { title: 'Unrelated',         text: '', public: false, group_id: '', verses: [[], []], timestamp: '2026-01-03 00:00:00.000000' },
        },
        next_cursor_created_at: null, next_cursor_id: null, has_more: false,
      }),
    });
    await notes.loadNotes();

    setFilter('title', 'faith');
    clickApply();

    expect(renderedIds('list-verse').sort()).toEqual(['n1', 'n2']);
  });

  test('sort desc (newest first), matching Sorting.sort_date(descending=True)', async () => {
    const { notes } = await importFreshModules();
    notes.initNotesSidebar();

    global.fetch = vi.fn().mockResolvedValueOnce({
      ok: true,
      json: async () => ({
        notes: {
          'oldest': { title: 'x', text: '', public: false, group_id: '', verses: [[], []], timestamp: '2026-01-01 00:00:00.000000' },
          'newest': { title: 'x', text: '', public: false, group_id: '', verses: [[], []], timestamp: '2026-03-01 00:00:00.000000' },
          'middle': { title: 'x', text: '', public: false, group_id: '', verses: [[], []], timestamp: '2026-02-01 00:00:00.000000' },
        },
        next_cursor_created_at: null, next_cursor_id: null, has_more: false,
      }),
    });
    await notes.loadNotes();

    setFilter('', '');
    setSort('desc');
    clickApply();

    expect(renderedIds('list-verse')).toEqual(['newest', 'middle', 'oldest']);
  });
});

describe('notes.js populateGroupSelector — groupTitleCache dedup (H13)', () => {
  test('re-invoking populateGroupSelector for an already-resolved group reuses the cached title, not a fresh fetch', async () => {
    const { notes } = await importFreshModules();

    global.fetch = vi.fn(async (url) => {
      if (url.includes('/user/user-1')) return { ok: true, json: async () => ({ groups: ['group-1'] }) };
      if (url.includes('/groups/user-1/group-1')) return { ok: true, json: async () => ({ group: { title: 'First Title' } }) };
      return { ok: false, status: 404, json: async () => ({}) };
    });

    await notes.populateGroupSelector();
    const groupFetchesAfterFirst = global.fetch.mock.calls.filter(([url]) => url.includes('/groups/user-1/group-1')).length;
    expect(groupFetchesAfterFirst).toBe(1);
    expect(document.getElementById('group-sel').options.length).toBe(2);
    expect(document.getElementById('group-sel').options[1].textContent).toBe('First Title');

    // Simulate populateGroupSelector being invoked again for the same group
    // (its own doc comment's stated scenario) by resetting the <select>'s
    // options the way a fresh render of the selector would -- the
    // `groupSel.options.length > 1` early-return guard only prevents a
    // redundant call while the selector is already populated in place, not
    // this case. Swap the mocked response so a stale-cache miss would be
    // detectable.
    document.getElementById('group-sel').innerHTML = '<option value="">Personal</option>';
    global.fetch = vi.fn(async (url) => {
      if (url.includes('/user/user-1')) return { ok: true, json: async () => ({ groups: ['group-1'] }) };
      if (url.includes('/groups/user-1/group-1')) return { ok: true, json: async () => ({ group: { title: 'Should Not Be Fetched Again' } }) };
      return { ok: false, status: 404, json: async () => ({}) };
    });
    await notes.populateGroupSelector();

    expect(global.fetch.mock.calls.some(([url]) => url.includes('/groups/user-1/group-1'))).toBe(false);
    expect(document.getElementById('group-sel').options[1].textContent).toBe('First Title');
  });
});
