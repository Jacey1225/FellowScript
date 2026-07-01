import { useState, useCallback, useRef } from 'react';
import { API } from '../config.js';
import { verseRefLabel } from '../utils.js';

function normalizeNote(n, username = '') {
  return {
    title:     n.title     ?? '',
    user:      username    || n.user || '',
    text:      n.text      ?? '',
    public:    n.public    ?? false,
    group_id:  n.group_id  ?? '',
    verses:    n.verses    ?? [],
    replies:   n.replies   ?? [],
    is_reply:  n.is_reply  ?? false,
    timestamp: n.timestamp ?? '',
  };
}

export function useNotes({ user, curBook, curChapter, vsValue }) {
  const [allNotes,        setAllNotes]        = useState({});
  const [groupNotes,      setGroupNotes]      = useState({});
  const [currentGroupId,  setCurrentGroupId]  = useState(() => {
    try { return localStorage.getItem('fs_notes_group') || null; } catch { return null; }
  });
  const [groups,          setGroups]          = useState([]);
  const [filteredNotes,   setFilteredNotes]   = useState(null);
  const [filteredGroup,   setFilteredGroup]   = useState(null);
  const [filterActive,    setFilterActive]    = useState(false);
  const notesCache = useRef({});

  // ── Load ──────────────────────────────────────────────────────────────────

  const loadNotes = useCallback(async () => {
    if (!user) return;
    try {
      const res = await fetch(`${API}/notes/${user.user_id}`);
      if (!res.ok) return;
      const data = await res.json();
      setAllNotes(data);
      notesCache.current[''] = data;
    } catch {}
  }, [user]);

  const loadGroupNotes = useCallback(async (groupId) => {
    if (!user || !groupId) return;
    try {
      const res = await fetch(`${API}/groups/${user.user_id}/${groupId}/notes`);
      if (res.ok) {
        const data = await res.json();
        setGroupNotes(data);
        notesCache.current[groupId] = data;
      }
    } catch {}
  }, [user]);

  const loadGroups = useCallback(async () => {
    if (!user) return;
    try {
      const res = await fetch(`${API}/user/${user.user_id}`);
      if (!res.ok) return;
      const data = await res.json();
      const groupList = await Promise.all((data.groups || []).map(async gid => {
        try {
          const r = await fetch(`${API}/groups/${user.user_id}/${gid}`);
          if (r.ok) {
            const d = await r.json();
            return { id: gid, title: d.group?.title || gid.slice(0, 8) };
          }
        } catch {}
        return { id: gid, title: gid.slice(0, 8) };
      }));
      setGroups(groupList);
    } catch {}
  }, [user]);

  const selectGroup = useCallback(async (groupId, onHighlightsNeeded) => {
    try { localStorage.setItem('fs_notes_group', groupId || ''); } catch {}
    setCurrentGroupId(groupId || null);
    setGroupNotes({});
    setFilteredGroup(null);
    setFilteredNotes(null);
    setFilterActive(false);
    if (groupId) {
      await loadGroupNotes(groupId);
      if (onHighlightsNeeded) await onHighlightsNeeded(groupId);
    }
  }, [loadGroupNotes]);

  // ── CRUD ──────────────────────────────────────────────────────────────────

  const saveNote = useCallback(async (noteData, editingId) => {
    if (!user) return false;
    const url = editingId
      ? `${API}/notes/${user.user_id}?note_id=${encodeURIComponent(editingId)}`
      : `${API}/notes/${user.user_id}`;
    try {
      const res = await fetch(url, {
        method: editingId ? 'PUT' : 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(noteData),
      });
      if (!res.ok) return false;
      const saved = await res.json();
      const savedId = editingId || saved.id;
      if (noteData.group_id) {
        setAllNotes(prev => { const n = { ...prev }; delete n[savedId]; return n; });
        await loadGroupNotes(noteData.group_id);
      } else {
        setAllNotes(prev => ({ ...prev, [savedId]: noteData }));
      }
      return true;
    } catch { return false; }
  }, [user, loadGroupNotes]);

  const deleteNote = useCallback(async (id) => {
    if (!user) return;
    try {
      await fetch(`${API}/notes/${user.user_id}?note_id=${encodeURIComponent(id)}`, { method: 'DELETE' });
      const deletedGroupId = allNotes[id]?.group_id;
      setAllNotes(prev => { const n = { ...prev }; delete n[id]; return n; });
      if (deletedGroupId) await loadGroupNotes(deletedGroupId);
    } catch {}
  }, [user, allNotes, loadGroupNotes]);

  const postReply = useCallback(async (noteId, text) => {
    if (!user || !currentGroupId || !text) return false;
    try {
      const res = await fetch(`${API}/notes/reply/${noteId}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          user: user.user_id, text, title: '', public: true,
          group_id: currentGroupId, replies: [], verses: [[], []], is_reply: true,
        }),
      });
      return res.ok;
    } catch { return false; }
  }, [user, currentGroupId]);

  const loadDetailReplies = useCallback(async (noteId) => {
    if (!user || !currentGroupId) return [];
    try {
      const res = await fetch(`${API}/groups/${user.user_id}/${noteId}/${currentGroupId}/replies`);
      if (res.ok) return await res.json();
    } catch {}
    return [];
  }, [user, currentGroupId]);

  // ── Filter / sort ─────────────────────────────────────────────────────────

  const applyFilter = useCallback(async ({ sortVal, filterType, filterVal, activeTab }) => {
    const isGroupTab = !!currentGroupId;
    const hasFilter  = !!(filterType && filterVal);
    const hasSort    = !!sortVal;

    if (!hasFilter && !hasSort) {
      setFilteredNotes(null);
      setFilteredGroup(null);
      setFilterActive(false);
      return;
    }

    const toFilter = { users: null, date: null, book: null, title: null };
    if (filterType === 'book')  toFilter.book  = filterVal;
    if (filterType === 'title') toFilter.title = filterVal;
    if (filterType === 'date')  toFilter.date  = filterVal;
    if (filterType === 'user')  toFilter.users = [filterVal];
    const toSort = { date: sortVal === 'desc', alpha: false, num_replies: false };

    try {
      let payload;
      if (isGroupTab) {
        const src = notesCache.current[currentGroupId] || groupNotes;
        payload = {};
        for (const [uname, notes] of Object.entries(src)) {
          payload[uname] = {};
          for (const [nid, n] of Object.entries(notes)) {
            payload[uname][nid] = normalizeNote(n, uname);
          }
        }
      } else {
        const subset = {};
        for (const [nid, n] of Object.entries(allNotes)) {
          subset[nid] = normalizeNote(n, user.username);
        }
        payload = { [user.user_id]: subset };
      }

      let result = payload;

      if (hasFilter) {
        const res = await fetch(`${API}/filter/`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ notes: result, to_filter: toFilter }),
        });
        if (res.ok) result = await res.json();
      }

      if (hasSort) {
        const flatNotes = {}, noteToUser = {};
        for (const [key, notes] of Object.entries(result)) {
          for (const [nid, data] of Object.entries(notes)) {
            flatNotes[nid] = data; noteToUser[nid] = key;
          }
        }
        const res = await fetch(`${API}/sort/`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ notes: flatNotes, to_sort: toSort }),
        });
        if (res.ok) {
          const sortedFlat = await res.json();
          const sortedResult = {};
          for (const [nid, data] of Object.entries(sortedFlat)) {
            const key = noteToUser[nid];
            if (!sortedResult[key]) sortedResult[key] = {};
            sortedResult[key][nid] = data;
          }
          result = sortedResult;
        }
      }

      if (isGroupTab) {
        setFilteredGroup(result);
        setFilteredNotes(null);
      } else {
        setFilteredNotes(result[user.user_id] || {});
        setFilteredGroup(null);
      }
      setFilterActive(true);
    } catch {}
  }, [user, allNotes, groupNotes, currentGroupId]);

  const clearFilter = useCallback(() => {
    setFilteredNotes(null);
    setFilteredGroup(null);
    setFilterActive(false);
  }, []);

  // ── Derived lists ─────────────────────────────────────────────────────────

  const getNoteRef = useCallback((id) => {
    return allNotes[id] || Object.values(groupNotes).reduce((found, notes) => found || notes[id], null);
  }, [allNotes, groupNotes]);

  const getVerse = useCallback((note) => verseRefLabel(note?.verses), []);

  return {
    allNotes, groupNotes, currentGroupId, groups,
    filteredNotes, filteredGroup, filterActive,
    loadNotes, loadGroupNotes, loadGroups, selectGroup,
    saveNote, deleteNote, postReply, loadDetailReplies,
    applyFilter, clearFilter, getNoteRef, getVerse,
  };
}
