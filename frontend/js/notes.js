// Notes sidebar: CRUD, rendering, group selector, note detail panel, sidebar resize.
// Exposes openEdit / deleteNote / openNoteDetail on window
// so inline onclick handlers in generated HTML can reach them.

import { API, user }    from './config.js';
import { escHtml, verseRefLabel } from './utils.js';
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

let editingId = null;
let activeTab = 'verse';

// ── Sidebar init ────────────────────────────────────────────────────────────

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
      document.getElementById('list-verse').style.display   = activeTab === 'verse'   ? 'flex' : 'none';
      document.getElementById('list-general').style.display = activeTab === 'general' ? 'flex' : 'none';
      document.getElementById('list-public').style.display  = activeTab === 'public'  ? 'flex' : 'none';
      noteForm.style.display = 'none';
    });
  });

  // New note
  newNoteBtn.addEventListener('click', () => {
    editingId = null;
    nfTitle.textContent = 'New Note';
    clearForm();
    if (curBook)    document.getElementById('nf-vs-book-s').value = curBook;
    if (curChapter) document.getElementById('nf-vs-ch-s').value   = curChapter;
    if (vsSel.value) document.getElementById('nf-vs-v-s').value   = vsSel.value;
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

    if (currentGroupId) {
      await Promise.all([_loadGroupNotes(currentGroupId), _loadGroupHighlights(currentGroupId)]);
    }

    renderAllLists();
    applyHighlights();
  });
}

// ── Group selector population ───────────────────────────────────────────────

export async function populateGroupSelector() {
  if (!user || groupSel.options.length > 1) return;
  try {
    const res = await fetch(`${API}/user/${user.user_id}`);
    if (!res.ok) return;
    const data = await res.json();
    await Promise.all((data.groups || []).map(async gid => {
      try {
        const r = await fetch(`${API}/groups/${user.user_id}/${gid}`);
        if (r.ok) {
          const d   = await r.json();
          const opt = document.createElement('option');
          opt.value       = gid;
          opt.textContent = d.group?.title || gid.slice(0, 8);
          groupSel.appendChild(opt);
        }
      } catch { /* skip */ }
    }));
  } catch { /* offline */ }
}

// ── Load ────────────────────────────────────────────────────────────────────

export async function loadNotes() {
  if (!user) return;
  try {
    const res = await fetch(`${API}/notes/${user.user_id}`);
    if (!res.ok) return;
    allNotes = await res.json();
    renderAllLists();
  } catch { /* server may not be running */ }
}

async function _loadGroupNotes(groupId) {
  try {
    const res = await fetch(`${API}/groups/${user.user_id}/${groupId}/notes`);
    if (res.ok) setGroupNotes(await res.json());
  } catch { /* offline */ }
}

async function _loadGroupHighlights(groupId) {
  try {
    const res = await fetch(`${API}/groups/${user.user_id}/${groupId}/highlights`);
    if (!res.ok) return;
    const highlights = await res.json();
    const usernames  = {};
    await Promise.all(Object.keys(highlights).map(async uid => {
      if (uid === user.user_id)  { usernames[uid] = user.username || 'Me'; return; }
      if (friendCache[uid])      { usernames[uid] = friendCache[uid]; return; }
      try {
        const r = await fetch(`${API}/user/${uid}`);
        if (r.ok) { const d = await r.json(); usernames[uid] = d.username || uid.slice(0, 4); }
      } catch { usernames[uid] = uid.slice(0, 4); }
    }));
    setGroupHighlightData(highlights, usernames);
  } catch { /* offline */ }
}

// ── Render ──────────────────────────────────────────────────────────────────

export function renderAllLists() {
  const verse   = [];
  const general = [];
  const pub     = [];

  Object.entries(allNotes).forEach(([id, note]) => {
    const hasVerse = note.verses && note.verses[0] && note.verses[0].length > 0;
    if (hasVerse)  verse.push([id, note, null]);
    if (!hasVerse) general.push([id, note, null]);
    if (!currentGroupId && note.public) pub.push([id, note, null]);
  });

  if (currentGroupId) {
    const myUsername = user?.username || '';
    Object.entries(groupNotes).forEach(([uname, notes]) => {
      Object.entries(notes).forEach(([id, note]) => {
        if (note.public) pub.push([id, note, uname, uname === myUsername, true]);
      });
    });
  }

  _renderList('list-verse',   verse,   'No verse notes yet.');
  _renderList('list-general', general, 'No general notes yet.');
  _renderList('list-public',  pub,     currentGroupId ? 'No public notes in this group.' : 'No public notes yet.');
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
    if (!res.ok) return;
    const saved = await res.json();
    allNotes[editingId || saved.id] = body;
    renderAllLists();
    noteForm.style.display = 'none';
    editingId = null;
    clearForm();
  } catch { /* server error */ }
}

export async function deleteNote(id) {
  if (!user || !confirm('Delete this note?')) return;
  try {
    await fetch(`${API}/notes/${user.user_id}?note_id=${encodeURIComponent(id)}`, { method: 'DELETE' });
    delete allNotes[id];
    renderAllLists();
  } catch { /* server error */ }
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
        if (!res.ok) return;
        input.value = '';
        await _loadDetailReplies(id);
      } catch { /* offline */ }
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
    if (!res.ok) { listEl.innerHTML = '<p class="note-empty" style="font-size:0.72rem">No replies yet.</p>'; return; }
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
  } catch { listEl.innerHTML = '<p class="note-empty" style="font-size:0.72rem">No replies yet.</p>'; }
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
