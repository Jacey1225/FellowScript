// Regression test for task 20260904-compliance-security-fixes (OWASP H2, security-gate
// bounce #1 on the frontend gate's first-pass fix).
//
// notes.js's _syncFilterInput() renders the "filter by user" radio list as a raw
// HTML template literal with the username interpolated directly into a quoted
// `value="..."` attribute (frontend/js/notes.js:75). The frontend gate's original
// fix wrapped the username in the file's shared escHtml() (utils.js), but escHtml()
// at the time only escaped &, <, > -- not quote characters -- so a username
// containing a double quote could still terminate the value="..." attribute early
// and inject arbitrary attributes/event handlers (e.g. onfocus="...") into the
// parsed DOM. The security gate caught this as a live attribute-injection stored-XSS
// gap; escHtml() was then extended to also escape " -> &quot; and ' -> &#39;.
//
// This test drives the real vulnerable path end-to-end: it mounts the actual
// filter-panel markup used by reader.html/index.html, calls notes.js's real
// initNotesSidebar() (which wires the fs-filter radio's real change listener to
// the real, unexported _syncFilterInput()), seeds groupNotes with a
// attribute-breakout-attempting username via highlights.js's real setGroupNotes(),
// and fires a real 'change' event -- rather than unit-testing escHtml() in
// isolation -- so a future regression that reintroduces raw interpolation at this
// call site (even via some other escaping helper) would still be caught.
//
// Run with: cd frontend && npm test -- --run js/notes.user-filter-escaping.test.js
import { describe, test, expect, vi, beforeEach } from 'vitest';

const USER = { user_id: 'user-1', username: 'tester' };

// Same module-scope DOM dependency list as notes.test.js, plus the filter-panel
// markup that test file doesn't need (it never exercises the filter panel).
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
  document.body.innerHTML =
    REQUIRED_IDS.map(id => `<div id="${id}"></div>`).join('') +
    `
    <div class="filter-panel" id="filter-panel">
      <button class="filter-back-btn" id="filter-back-btn">&#8592;</button>
      <span class="filter-active-badge" id="filter-active-badge" style="display:none">Active</span>
      <div class="filter-section">
        <label class="filter-radio-row"><input type="radio" name="fs-filter" value=""      checked /><span>None</span></label>
        <label class="filter-radio-row"><input type="radio" name="fs-filter" value="book"         /><span>Book</span></label>
        <label class="filter-radio-row"><input type="radio" name="fs-filter" value="title"        /><span>Title contains</span></label>
        <label class="filter-radio-row"><input type="radio" name="fs-filter" value="date"         /><span>Date</span></label>
        <label class="filter-radio-row"><input type="radio" name="fs-filter" value="user"         /><span>User</span></label>
      </div>
      <div id="fs-input-wrap" style="display:none">
        <input id="fs-input" class="fs-value-input" type="text" placeholder="" />
      </div>
      <div id="fs-user-list" style="display:none" class="filter-section"></div>
      <div class="filter-btns">
        <button class="form-btn save"   id="fs-apply">Apply</button>
        <button class="form-btn cancel" id="fs-clear">Clear</button>
      </div>
    </div>
    <button class="sidebar-head-filter-btn" id="sidebar-open-filter-btn"></button>
    `;
}

async function importFreshModules() {
  vi.resetModules();
  mountShell();
  sessionStorage.setItem('user', JSON.stringify(USER));
  // Import in this order, without an intervening resetModules(), so notes.js's
  // internal `import { groupNotes, setGroupNotes } from './highlights.js'`
  // resolves to the exact same module instance this test mutates directly.
  const highlights = await import('./highlights.js');
  const notes = await import('./notes.js');
  return { highlights, notes };
}

beforeEach(() => {
  global.fetch = vi.fn();
  sessionStorage.clear();
  localStorage.clear();
});

describe('notes.js "filter by user" list — attribute-injection regression (OWASP H2)', () => {
  test('a username containing a double quote cannot break out of the fs-user value="..." attribute', async () => {
    const { highlights, notes } = await importFreshModules();
    notes.initNotesSidebar();

    const malicious = 'x" onfocus="autofocus" onfocus="alert(document.cookie)';
    highlights.setGroupNotes({ [malicious]: {} });

    const userRadio = document.querySelector('input[name="fs-filter"][value="user"]');
    userRadio.checked = true;
    userRadio.dispatchEvent(new Event('change', { bubbles: true }));

    const userList = document.getElementById('fs-user-list');
    const renderedInputs = userList.querySelectorAll('input[name="fs-user"]');

    // Exactly one radio was rendered for the one malicious username -- if the
    // quote had broken out of the attribute, the parser would instead produce
    // extra/mangled elements (e.g. the injected onfocus="..." string reparsed
    // as bogus markup) rather than a single clean <input>.
    expect(renderedInputs.length).toBe(1);

    const renderedInput = renderedInputs[0];
    // No injected attribute made it onto the element.
    expect(renderedInput.getAttribute('onfocus')).toBeNull();
    expect(renderedInput.autofocus).toBe(false);
    // The value attribute round-trips to the literal malicious string (proving
    // it was safely entity-encoded on the way in and decoded back on the way
    // out), rather than being truncated at the first raw quote.
    expect(renderedInput.value).toBe(malicious);

    // The visible <span> label alongside it is unaffected by the same fix.
    const label = userList.querySelector('.filter-radio-row span');
    expect(label.textContent).toBe(malicious);
  });

  test('a plain username with no special characters still renders and filters normally', async () => {
    const { highlights, notes } = await importFreshModules();
    notes.initNotesSidebar();

    highlights.setGroupNotes({ 'plainuser': {} });

    const userRadio = document.querySelector('input[name="fs-filter"][value="user"]');
    userRadio.checked = true;
    userRadio.dispatchEvent(new Event('change', { bubbles: true }));

    const userList = document.getElementById('fs-user-list');
    const renderedInput = userList.querySelector('input[name="fs-user"]');
    expect(renderedInput.value).toBe('plainuser');
    expect(userList.style.display).toBe('flex');
  });
});
