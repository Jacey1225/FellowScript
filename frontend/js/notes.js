// Notes sidebar: CRUD, rendering, group selector, note detail panel, sidebar resize.
// Exposes openEdit / deleteNote / openNoteDetail on window
// so inline onclick handlers in generated HTML can reach them.

import { API, user }    from './config.js';
import { escHtml, verseRefLabel, unwrapNotesEnvelope } from './utils.js';
import { curBook, curChapter, vsSel } from './bible.js';
import {
  currentGroupId, groupNotes,
  setCurrentGroupId, setGroupNotes, setGroupHighlightData,
  applyHighlights,
} from './highlights.js';
import { friendCache } from './messaging.js';

const sidebar       = document.getElementById('notes-sidebar');
const sidebarTgl    = document.getElementById('sidebar-toggle');
const newNoteBtn    = document.getElementById('new-note-btn');
const noteForm      = document.getElementById('note-form');
const nfTitle       = document.getElementById('note-form-title');
const nfSave        = document.getElementById('nf-save');
const nfCancel      = document.getElementById('nf-cancel');
const groupSel      = document.getElementById('group-sel');
const noteDetail    = document.getElementById('note-detail');
const notesMain     = document.getElementById('notes-main');
const detailTitleEl = document.getElementById('note-detail-title');
const detailBodyEl  = document.getElementById('note-detail-body');

export let allNotes = {};

const notesCache = {}; // keyed by group_id; '' = personal notes

// H13 (compliance sweep) -- client-side dedup for populateGroupSelector's
// N+1 fetch-per-group pattern, mirroring the friendCache-style memoization
// used elsewhere (notes.js's _loadGroupHighlights below, messaging.js's own
// friendCache). Keyed by group id, populated once and reused if
// populateGroupSelector is ever invoked again for the same group. A real
// batched endpoint (this task's own deferred H13 follow-up -- see
// intake-spec.md's Open Questions) would let this, useNotes.js's
// loadGroups, and useMessaging.js's loadContacts all share one fetch
// instead of three independently-cached ones.
const groupTitleCache = {};

let editingId          = null;
let activeTab          = 'verse';
let filteredNotes      = null;
let filteredGroupNotes = null;

// ── Filter panel ─────────────────────────────────────────────────────────────

function _openFilterPanel()  { document.getElementById('filter-panel').classList.add('open');    }
function _closeFilterPanel() { document.getElementById('filter-panel').classList.remove('open'); }

// Ensure every field the Note schema expects is present before sending to the backend.
// Falls back to safe defaults so Pydantic never sees missing required fields.
function _normalizeNote(n, username = '') {
  return {
    title:     n.title     ?? '',
    user:      username    || n.user || '',
    text:      n.text      ?? '',
    public:    n.public    ?? false,
    group_id:  n.group_id  ?? '',
    verses:    n.verses    ?? [[], []],
    replies:   n.replies   ?? [],
    is_reply:  n.is_reply  ?? false,
    timestamp: n.timestamp ?? '',
  };
}

// Compliance sweep, optimization #4 -- _applyFiltersAndSort's notes are
// already in memory client-side (allNotes/groupNotes/notesCache); round-
// tripping them through POST /filter/ and POST /sort/ just to re-derive the
// same predicate the backend already applies is pure overhead. These two
// functions mirror api/backend/filters/filter_notes.py's Filters/Sorting
// classes exactly (same predicates, same nested-dict shape in/out) so a
// caller gets identical results without the network round trip.
function _localFilterNotes(notes, toFilter) {
  let predicate;
  if (toFilter.book) {
    const needle = toFilter.book.toLowerCase();
    predicate = note => (note.verses || []).some(v => v && String(v[0] ?? '').toLowerCase().includes(needle));
  } else if (toFilter.date) {
    const target = toFilter.date.slice(0, 10);
    predicate = note => (note.timestamp || '').slice(0, 10) === target;
  } else if (toFilter.users) {
    predicate = note => toFilter.users.includes(note.user);
  } else if (toFilter.title) {
    const needle = toFilter.title.toLowerCase();
    predicate = note => (note.title || '').toLowerCase().includes(needle);
  } else {
    return notes;
  }

  const result = {};
  for (const [uid, byId] of Object.entries(notes)) {
    for (const [nid, note] of Object.entries(byId)) {
      if (!predicate(note)) continue;
      if (!result[uid]) result[uid] = {};
      result[uid][nid] = note;
    }
  }
  return result;
}

// `descending`: true = newest first, matching Sorting.sort_date's
// `reverse=descending`. An unparseable timestamp sorts as the oldest
// possible value, matching the backend's datetime.min fallback.
function _localSortNotesByDate(flatNotes, descending) {
  const withDates = Object.entries(flatNotes).map(([nid, note]) => {
    const t = Date.parse(note.timestamp);
    return [nid, Number.isNaN(t) ? -Infinity : t];
  });
  withDates.sort((a, b) => (descending ? b[1] - a[1] : a[1] - b[1]));

  const sorted = {};
  for (const [nid] of withDates) sorted[nid] = flatNotes[nid];
  return sorted;
}

function _syncFilterInput() {
  const type     = document.querySelector('input[name="fs-filter"]:checked')?.value || '';
  const wrap     = document.getElementById('fs-input-wrap');
  const inp      = document.getElementById('fs-input');
  const userList = document.getElementById('fs-user-list');

  wrap.style.display     = 'none';
  userList.style.display = 'none';
  inp.value = '';

  if (!type) return;

  if (type === 'user') {
    const names = Object.keys(groupNotes);
    if (!names.length) return;
    userList.innerHTML = names
      .map(n => `<label class="filter-radio-row">
        <input type="radio" name="fs-user" value="${escHtml(n)}" />
        <span>${escHtml(n)}</span>
      </label>`)
      .join('');
    userList.style.display = 'flex';
    userList.style.flexDirection = 'column';
  } else {
    wrap.style.display = 'block';
    if (type === 'date') { inp.type = 'date'; inp.placeholder = ''; }
    else {
      inp.type = 'text';
      inp.placeholder = type === 'book' ? 'e.g. Genesis' : 'Search…';
    }
  }
}

function _updateFilterBtn() {
  const isActive = filteredNotes !== null || filteredGroupNotes !== null;
  document.getElementById('sidebar-open-filter-btn')?.classList.toggle('active', isActive);
  const badge = document.getElementById('filter-active-badge');
  if (badge) badge.style.display = isActive ? '' : 'none';
}

function _applyFiltersAndSort() {
  const sortVal    = document.querySelector('input[name="fs-sort"]:checked')?.value   || '';
  const filterType = document.querySelector('input[name="fs-filter"]:checked')?.value || '';
  const filterVal  = filterType === 'user'
    ? (document.querySelector('#fs-user-list input[name="fs-user"]:checked')?.value || '')
    : document.getElementById('fs-input').value.trim();

  const hasFilter  = !!(filterType && filterVal);
  const hasSort    = !!sortVal;
  const isGroupTab = activeTab === 'public' && !!currentGroupId;

  if (!hasFilter && !hasSort) {
    filteredNotes      = null;
    filteredGroupNotes = null;
    _updateFilterBtn();
    renderAllLists();
    _closeFilterPanel();
    return;
  }

  const toFilter = { users: null, date: null, book: null, title: null };
  if (filterType === 'book')  toFilter.book  = filterVal;
  if (filterType === 'title') toFilter.title = filterVal;
  if (filterType === 'date')  toFilter.date  = filterVal;
  if (filterType === 'user')  toFilter.users = [filterVal];
  const toSort = { date: sortVal === 'desc', alpha: false, num_replies: false };

  try {
    // Build payload as new objects via _normalizeNote — originals (allNotes, groupNotes,
    // notesCache) are never mutated, so changing filter type always re-reads the full set.
    let payload;
    if (isGroupTab) {
      // Group tab: all members' notes from the cached group snapshot.
      const src = notesCache[currentGroupId] || groupNotes;
      payload = {};
      for (const [uname, notes] of Object.entries(src)) {
        payload[uname] = {};
        for (const [nid, n] of Object.entries(notes)) {
          payload[uname][nid] = _normalizeNote(n, uname);
        }
      }
    } else {
      // Personal tab: only notes without a group_id, scoped to the active tab type.
      const subset = {};
      for (const [nid, n] of Object.entries(allNotes)) {
        if (n.group_id) continue;
        const norm = _normalizeNote(n, user.username);
        if (activeTab === 'public' && !norm.public) continue;
        subset[nid] = norm;
      }
      payload = { [user.user_id]: subset };
    }

    const totalNotes = Object.values(payload).reduce((s, v) => s + Object.keys(v).length, 0);
    console.log(`[filter] tab=${activeTab} isGroupTab=${isGroupTab} groupId=${currentGroupId}`);
    console.log(`[filter] payload: ${Object.keys(payload).length} user(s), ${totalNotes} note(s)`);

    // Filter/sort locally instead of round-tripping through POST /filter/ and
    // POST /sort/ — see _localFilterNotes/_localSortNotesByDate above.
    let result = payload;

    if (hasFilter) {
      console.log('[filter] applying locally →', toFilter);
      result = _localFilterNotes(result, toFilter);
      const n = Object.values(result).reduce((s, v) => s + Object.keys(v).length, 0);
      console.log('[filter] local filter result:', n, 'note(s) across', Object.keys(result).length, 'user(s)');
    }

    if (hasSort) {
      // Flatten all users' notes into one dict so a single sort produces a
      // globally ordered result instead of independent per-user sorted blocks.
      console.log('[filter] sorting locally →', toSort);
      const flatNotes  = {};
      const noteToUser = {};
      for (const [key, notes] of Object.entries(result)) {
        for (const [nid, data] of Object.entries(notes)) {
          flatNotes[nid]  = data;
          noteToUser[nid] = key;
        }
      }
      const sortedFlat = _localSortNotesByDate(flatNotes, toSort.date);
      // Rebuild nested structure in globally-sorted insertion order.
      const sortedResult = {};
      for (const [nid, data] of Object.entries(sortedFlat)) {
        const key = noteToUser[nid];
        if (!sortedResult[key]) sortedResult[key] = {};
        sortedResult[key][nid] = data;
      }
      result = sortedResult;
      console.log('[filter] local sort done');
    }

    if (isGroupTab) {
      filteredGroupNotes = result;
      filteredNotes      = null;
    } else {
      filteredNotes      = result[user.user_id] || {};
      filteredGroupNotes = null;
    }
  } catch (err) {
    console.error('[filter] error:', err);
  }

  _updateFilterBtn();
  renderAllLists();
  _closeFilterPanel();
}

function _clearFilter() {
  document.querySelectorAll('input[name="fs-sort"]').forEach((r, i)   => { r.checked = i === 0; });
  document.querySelectorAll('input[name="fs-filter"]').forEach((r, i) => { r.checked = i === 0; });
  document.getElementById('fs-input').value              = '';
  document.getElementById('fs-input-wrap').style.display = 'none';
  document.querySelectorAll('#fs-user-list input[name="fs-user"]').forEach(r => { r.checked = false; });
  document.getElementById('fs-user-list').style.display  = 'none';
  filteredNotes      = null;
  filteredGroupNotes = null;
  _updateFilterBtn();
  renderAllLists();
}

// ── Sidebar init ─────────────────────────────────────────────────────────────

export function initNotesSidebar() {
  sidebarTgl.addEventListener('click', () => {
    const open = sidebar.classList.toggle('open');
    document.body.classList.toggle('sidebar-open', open);
    if (open && user) { loadNotes(); populateGroupSelector(); }
  });

  if (!user) {
    document.getElementById('notes-signin').style.display = 'flex';
    newNoteBtn.style.display = 'none';
    document.querySelectorAll('.stab, .notes-list').forEach(el => el.style.display = 'none');
    const filterBtn = document.getElementById('sidebar-open-filter-btn');
    if (filterBtn) filterBtn.style.display = 'none';
    return;
  }

  // Detail panel back button
  document.getElementById('note-detail-back')?.addEventListener('click', _closeDetail);


  // Tab switching
  document.querySelectorAll('.stab').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.stab').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      activeTab = btn.dataset.tab;
      document.getElementById('list-verse').style.display  = activeTab === 'verse'  ? 'flex' : 'none';
      document.getElementById('list-public').style.display = activeTab === 'public' ? 'flex' : 'none';
      noteForm.style.display = 'none';
      renderAllLists();
    });
  });

  // New note
  newNoteBtn.addEventListener('click', () => {
    editingId = null;
    nfTitle.textContent = 'New Note';
    clearForm();
    if (curBook)     document.getElementById('nf-vs-book-s').value = curBook;
    if (curChapter)  document.getElementById('nf-vs-ch-s').value   = curChapter;
    if (vsSel.value) document.getElementById('nf-vs-v-s').value    = vsSel.value;
    noteForm.style.display = 'flex';
    noteForm.scrollIntoView({ block: 'nearest' });
  });

  nfCancel.addEventListener('click', () => {
    noteForm.style.display = 'none';
    editingId = null;
    clearForm();
  });

  nfSave.addEventListener('click', _saveNote);

  // Group selector
  groupSel.addEventListener('change', async () => {
    setCurrentGroupId(groupSel.value || null);
    setGroupNotes({});
    setGroupHighlightData({}, {});
    filteredGroupNotes = null;
    filteredNotes      = null;
    _updateFilterBtn();

    if (currentGroupId) {
      await Promise.all([_loadGroupNotes(currentGroupId), _loadGroupHighlights(currentGroupId)]);
    }

    renderAllLists();
    applyHighlights();
  });

  // Filter panel
  document.getElementById('sidebar-open-filter-btn')?.addEventListener('click', _openFilterPanel);
  document.getElementById('filter-back-btn')?.addEventListener('click', _closeFilterPanel);
  document.querySelectorAll('input[name="fs-filter"]').forEach(r =>
    r.addEventListener('change', _syncFilterInput));
  document.getElementById('fs-apply')?.addEventListener('click', _applyFiltersAndSort);
  document.getElementById('fs-clear')?.addEventListener('click', _clearFilter);
}

// ── Group selector population ───────────────────────────────────────────────

export async function populateGroupSelector() {
  if (!user || groupSel.options.length > 1) return;
  try {
    const res = await fetch(`${API}/user/${user.user_id}`);
    if (!res.ok) { console.warn('[notes] populateGroupSelector: /user fetch failed', res.status); return; }
    const data = await res.json();
    await Promise.all((data.groups || []).map(async gid => {
      if (groupTitleCache[gid]) {
        const opt = document.createElement('option');
        opt.value       = gid;
        opt.textContent = groupTitleCache[gid];
        groupSel.appendChild(opt);
        return;
      }
      try {
        const r = await fetch(`${API}/groups/${user.user_id}/${gid}`);
        if (r.ok) {
          const d     = await r.json();
          const title = d.group?.title || gid.slice(0, 8);
          groupTitleCache[gid] = title;
          const opt = document.createElement('option');
          opt.value       = gid;
          opt.textContent = title;
          groupSel.appendChild(opt);
        } else {
          console.warn('[notes] populateGroupSelector: group fetch failed', gid, r.status);
        }
      } catch (err) { console.error('[notes] populateGroupSelector: group fetch error', gid, err); }
    }));
  } catch (err) { console.error('[notes] populateGroupSelector error:', err); }
}

// ── Load ────────────────────────────────────────────────────────────────────

export async function loadNotes() {
  if (!user) return;
  try {
    const res = await fetch(`${API}/notes/${user.user_id}`);
    if (!res.ok) { console.warn('[notes] loadNotes failed', res.status); return; }
    const payload = await res.json();
    // Backend now returns one keyset-paginated page as
    // {notes, next_cursor_created_at, next_cursor_id, has_more} instead of a
    // bare {note_id: note} dict -- unwrap .notes so allNotes keeps its
    // existing shape. This view intentionally keeps its current full-list
    // loading behavior and just always sees the first capped page.
    // unwrapNotesEnvelope also fails safe (empty, not the raw envelope) if
    // .notes is ever missing or malformed -- see its doc comment.
    allNotes = unwrapNotesEnvelope(payload);
    notesCache[''] = allNotes;
    console.log('[notes] personal notes loaded:', Object.keys(allNotes).length);
    renderAllLists();
  } catch (err) { console.error('[notes] loadNotes error:', err); }
}

async function _loadGroupNotes(groupId) {
  try {
    const res = await fetch(`${API}/groups/${user.user_id}/${groupId}/notes`);
    if (res.ok) {
      const payload = await res.json();
      // Same envelope unwrap as loadNotes above.
      const data = unwrapNotesEnvelope(payload);
      setGroupNotes(data);
      notesCache[groupId] = data;
      const total = Object.values(data).reduce((s, u) => s + Object.keys(u).length, 0);
      console.log(`[notes] group ${groupId} loaded: ${total} notes across`, Object.keys(data).length, 'users');
    } else {
      console.warn('[notes] _loadGroupNotes failed', groupId, res.status);
    }
  } catch (err) { console.error('[notes] _loadGroupNotes error:', groupId, err); }
}

async function _loadGroupHighlights(groupId) {
  try {
    const res = await fetch(`${API}/groups/${user.user_id}/${groupId}/highlights`);
    if (!res.ok) { console.warn('[notes] _loadGroupHighlights failed', groupId, res.status); return; }
    const highlights = await res.json();
    const usernames  = {};
    await Promise.all(Object.keys(highlights).map(async uid => {
      if (uid === user.user_id)  { usernames[uid] = user.username || 'Me'; return; }
      if (friendCache[uid])      { usernames[uid] = friendCache[uid]; return; }
      try {
        const r = await fetch(`${API}/user/${uid}`);
        if (r.ok) { const d = await r.json(); usernames[uid] = d.username || uid.slice(0, 4); }
        else { console.warn('[notes] _loadGroupHighlights: /user fetch failed', uid, r.status); usernames[uid] = uid.slice(0, 4); }
      } catch (err) { console.error('[notes] _loadGroupHighlights: /user fetch error', uid, err); usernames[uid] = uid.slice(0, 4); }
    }));
    setGroupHighlightData(highlights, usernames);
  } catch (err) { console.error('[notes] _loadGroupHighlights error:', groupId, err); }
}

// ── Render ──────────────────────────────────────────────────────────────────

export function renderAllLists() {
  const _src      = filteredNotes ?? allNotes;
  const _filtered = filteredNotes !== null;
  const verse = [];
  const pub   = [];

  Object.entries(_src).forEach(([id, note]) => {
    if (note.group_id) return; // group notes rendered separately via groupNotes
    verse.push([id, note, null]); // all personal notes go to the Notes tab
    if (note.public) pub.push([id, note, null]);
  });

  if (currentGroupId) {
    const myUsername = user?.username || '';
    const groupSrc   = filteredGroupNotes ?? groupNotes;
    Object.entries(groupSrc).forEach(([uname, notes]) => {
      Object.entries(notes).forEach(([id, note]) => {
        if (note.public) pub.push([id, note, uname, uname === myUsername, true]);
      });
    });
    // Re-sort pub globally after building from nested per-user structure,
    // so notes from different users are interleaved in the correct date order.
    if (filteredGroupNotes !== null) {
      const dir = document.querySelector('input[name="fs-sort"]:checked')?.value || '';
      if (dir) {
        pub.sort((a, b) => {
          const da = new Date(a[1].timestamp), db = new Date(b[1].timestamp);
          return dir === 'desc' ? db - da : da - db;
        });
      }
    }
  }

  _renderList('list-verse',  verse, _filtered ? 'No notes match this filter.' : 'No notes yet.');
  _renderList('list-public', pub,   currentGroupId ? 'No public notes in this group.' : 'No public notes yet.');
}

function _renderList(listId, entries, emptyMsg) {
  const el = document.getElementById(listId);
  if (entries.length === 0) {
    el.innerHTML = `<p class="note-empty">${emptyMsg}</p>`;
    return;
  }
  el.innerHTML = entries
    .map(([id, note, owner, isOwn, canReply]) => _noteCardHTML(id, note, owner, isOwn, canReply))
    .join('');
}

function _noteCardHTML(id, note, owner, isOwn = false) {
  const ref        = verseRefLabel(note.verses);
  const pubBadge   = note.public ? '<span class="note-public-badge">Public</span>' : '';
  const ownerBadge = owner ? `<span class="note-owner-badge">${escHtml(owner)}</span>` : '';
  const canEdit    = !owner || isOwn;

  const actions = canEdit ? `
      <div class="note-card-actions">
        <button class="note-action-btn" title="Edit"   onclick="openEdit('${id}')">✎</button>
        <button class="note-action-btn" title="Delete" onclick="deleteNote('${id}')">✕</button>
      </div>` : '';

  return `
    <div class="note-card" id="nc-${id}"
         onclick="if(!event.target.closest('.note-action-btn'))openNoteDetail('${id}')">
      <div class="note-card-head">
        <span class="note-card-title">${escHtml(note.title)}${pubBadge}${ownerBadge}</span>
        ${actions}
      </div>
      ${ref ? `<span class="note-verse-ref">${escHtml(ref)}</span>` : ''}
      <p class="note-card-text" id="nt-${id}">${escHtml(note.text)}</p>
    </div>`;
}

// ── CRUD ────────────────────────────────────────────────────────────────────

export function openEdit(id) {
  editingId = id;
  const note = allNotes[id];
  nfTitle.textContent = 'Edit Note';
  document.getElementById('nf-title').value    = note.title   || '';
  document.getElementById('nf-text').value     = note.text    || '';
  document.getElementById('nf-public').checked = !!note.public;
  const [s, e] = note.verses || [[], []];
  document.getElementById('nf-vs-book-s').value = s[0] || '';
  document.getElementById('nf-vs-ch-s').value   = s[1] || '';
  document.getElementById('nf-vs-v-s').value    = s[2] || '';
  document.getElementById('nf-vs-book-e').value = e[0] || '';
  document.getElementById('nf-vs-ch-e').value   = e[1] || '';
  document.getElementById('nf-vs-v-e').value    = e[2] || '';
  noteForm.style.display = 'flex';
  noteForm.scrollIntoView({ block: 'nearest' });
}
window.openEdit = openEdit;

async function _saveNote() {
  if (!user) return;
  const bookS = document.getElementById('nf-vs-book-s').value.trim();
  const chS   = parseInt(document.getElementById('nf-vs-ch-s').value) || null;
  const vsS   = parseInt(document.getElementById('nf-vs-v-s').value)  || null;
  const bookE = document.getElementById('nf-vs-book-e').value.trim();
  const chE   = parseInt(document.getElementById('nf-vs-ch-e').value) || null;
  const vsE   = parseInt(document.getElementById('nf-vs-v-e').value)  || null;
  const hasStart = bookS && chS && vsS;
  const hasEnd   = bookE && chE && vsE;
  const isPublic = document.getElementById('nf-public').checked;

  const body = {
    user:     user.user_id,
    group_id: editingId
      ? (allNotes[editingId]?.group_id || '')
      : (isPublic && currentGroupId ? currentGroupId : ''),
    replies:  editingId ? (allNotes[editingId]?.replies || []) : [],
    title:    document.getElementById('nf-title').value.trim() || 'Note',
    text:     document.getElementById('nf-text').value.trim(),
    public:   isPublic,
    verses:   hasStart
      ? [[bookS, chS, vsS], hasEnd ? [bookE, chE, vsE] : [bookS, chS, vsS]]
      : [[], []],
  };

  const url = editingId
    ? `${API}/notes/${user.user_id}?note_id=${encodeURIComponent(editingId)}`
    : `${API}/notes/${user.user_id}`;

  try {
    const res = await fetch(url, {
      method:  editingId ? 'PUT' : 'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify(body),
    });
    if (!res.ok) {
      // A failed save must not be treated as if the form had been submitted --
      // leave the form open with the user's input intact and tell them, rather
      // than silently discarding their note (mirrors deleteNote's fail-visible
      // handling below).
      console.warn('[notes] _saveNote failed', res.status);
      alert('Could not save that note. Please try again.');
      return;
    }
    const saved = await res.json();
    allNotes[editingId || saved.id] = body;
    if (body.group_id) await _loadGroupNotes(body.group_id);
    renderAllLists();
    noteForm.style.display = 'none';
    editingId = null;
    clearForm();
  } catch (err) {
    console.error('[notes] _saveNote error:', err);
    alert('Could not save that note. Check your connection and try again.');
  }
}

export async function deleteNote(id) {
  if (!user || !confirm('Delete this note?')) return;
  try {
    const res = await fetch(`${API}/notes/${user.user_id}?note_id=${encodeURIComponent(id)}`, { method: 'DELETE' });
    if (!res.ok) {
      // A failed delete (expired session, 403, 500...) must not be treated
      // as a successful one -- the note stayed on the server, so it must
      // stay in the local list too.
      console.warn('[notes] deleteNote failed', id, res.status);
      alert('Could not delete that note. Please try again.');
      return;
    }
    // The backend's own GET /notes/{user_id} filters to group_id IS NULL, so
    // a group note is never present in allNotes to begin with -- looking up
    // its group_id there always misses, and the group's note list silently
    // never refreshed after a delete. groupNotes (loaded for whichever
    // group is currently selected) is the only place a group note's data
    // actually lives client-side, so check there too, scoped to the
    // currently selected group tab.
    let deletedGroupId = allNotes[id]?.group_id || null;
    if (!deletedGroupId && currentGroupId) {
      const inCurrentGroup = Object.values(groupNotes).some(notes => notes[id]);
      if (inCurrentGroup) deletedGroupId = currentGroupId;
    }
    delete allNotes[id];
    if (deletedGroupId) await _loadGroupNotes(deletedGroupId);
    renderAllLists();
  } catch (err) {
    console.error('[notes] deleteNote error:', id, err);
    alert('Could not delete that note. Check your connection and try again.');
  }
}
window.deleteNote = deleteNote;

// ── Note detail panel ────────────────────────────────────────────────────────

function _closeDetail() {
  noteDetail.style.display = 'none';
  notesMain.style.display  = 'flex';
}

export function openNoteDetail(id) {
  let note     = allNotes[id] || null;
  let canReply = false;

  if (!note) {
    for (const [, notes] of Object.entries(groupNotes)) {
      if (notes[id]) { note = notes[id]; canReply = !!currentGroupId; break; }
    }
  }
  if (!note) return;

  const ref = verseRefLabel(note.verses);
  detailTitleEl.textContent = note.title || 'Untitled';

  const replyFormHTML = canReply ? `
    <div class="note-detail-reply-form">
      <textarea class="note-reply-input" id="nd-reply-input" placeholder="Write a reply…" rows="2"></textarea>
      <button class="note-reply-submit" id="nd-reply-submit">Reply</button>
    </div>` : '';

  detailBodyEl.innerHTML = `
    ${ref ? `<span class="note-detail-ref">${escHtml(ref)}</span>` : ''}
    <p class="note-detail-text">${escHtml(note.text || '')}</p>
    ${canReply ? `
    <hr class="note-detail-divider">
    <span class="note-detail-replies-label">Replies</span>
    <div id="nd-replies-list"><p class="note-empty" style="font-size:0.72rem">Loading…</p></div>
    ${replyFormHTML}` : ''}
  `;

  notesMain.style.display  = 'none';
  noteDetail.style.display = 'flex';

  if (canReply) {
    detailBodyEl.querySelector('#nd-reply-submit')?.addEventListener('click', async () => {
      const input = detailBodyEl.querySelector('#nd-reply-input');
      const text  = input?.value.trim();
      if (!text || !user || !currentGroupId) return;
      try {
        const res = await fetch(`${API}/notes/reply/${id}`, {
          method:  'POST',
          headers: { 'Content-Type': 'application/json' },
          body:    JSON.stringify({
            user: user.user_id, text, title: '', public: true,
            group_id: currentGroupId, replies: [], verses: [[], []], is_reply: true,
          }),
        });
        if (!res.ok) {
          console.warn('[notes] reply submit failed', id, res.status);
          alert('Could not post that reply. Please try again.');
          return;
        }
        input.value = '';
        await _loadDetailReplies(id);
      } catch (err) {
        console.error('[notes] reply submit error:', id, err);
        alert('Could not post that reply. Check your connection and try again.');
      }
    });
    _loadDetailReplies(id);
  }
}
window.openNoteDetail = openNoteDetail;

async function _loadDetailReplies(noteId) {
  const listEl = document.getElementById('nd-replies-list');
  if (!listEl || !user || !currentGroupId) return;
  try {
    const res = await fetch(`${API}/groups/${user.user_id}/${noteId}/${currentGroupId}/replies`);
    if (!res.ok) {
      // Don't collapse a failed load into "no replies" -- that's the same
      // silently-substituted-default bug already fixed elsewhere in this
      // codebase (compile-errors #5); tell the user the load failed instead.
      console.warn('[notes] _loadDetailReplies failed', noteId, res.status);
      listEl.innerHTML = '<p class="note-empty" style="font-size:0.72rem">Could not load replies. Please try again.</p>';
      return;
    }
    const replies = await res.json();
    if (!Array.isArray(replies) || replies.length === 0) {
      listEl.innerHTML = '<p class="note-empty" style="font-size:0.72rem">No replies yet.</p>';
      return;
    }
    listEl.innerHTML = replies.map(r => `
      <div class="note-reply-item">
        <span class="note-reply-author">${escHtml(r.user || '')}</span>
        <p class="note-reply-text">${escHtml(r.text || '')}</p>
      </div>`).join('');
  } catch (err) {
    console.error('[notes] _loadDetailReplies error:', noteId, err);
    listEl.innerHTML = '<p class="note-empty" style="font-size:0.72rem">Could not load replies. Please try again.</p>';
  }
}

// ── Sidebar resize ──────────────────────────────────────────────────────────

export function initSidebarResize() {
  const handle = document.getElementById('sidebar-resize-handle');
  const MIN_W  = 220;
  const MAX_W  = 700;

  handle.addEventListener('mousedown', e => {
    e.preventDefault();
    handle.classList.add('dragging');
    document.body.style.userSelect = 'none';
    document.body.style.cursor     = 'ew-resize';

    const onMove = ev => {
      const newW = Math.min(MAX_W, Math.max(MIN_W, window.innerWidth - ev.clientX));
      sidebar.style.width = newW + 'px';
      document.documentElement.style.setProperty('--sidebar-w', newW + 'px');
    };
    const onUp = () => {
      handle.classList.remove('dragging');
      document.body.style.userSelect = '';
      document.body.style.cursor     = '';
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
    };

    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
  });
}

// ── Form helpers ─────────────────────────────────────────────────────────────

export function clearForm() {
  ['nf-title', 'nf-text', 'nf-vs-book-s', 'nf-vs-ch-s', 'nf-vs-v-s',
   'nf-vs-book-e', 'nf-vs-ch-e', 'nf-vs-v-e'].forEach(id => {
    document.getElementById(id).value = '';
  });
  document.getElementById('nf-public').checked = false;
}
