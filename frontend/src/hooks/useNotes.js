import { useState, useCallback, useRef } from 'react';
import { message } from 'antd';
import { API } from '../config.js';
import { verseRefLabel, unwrapNotesEnvelope } from '../utils.js';

// Shows a friendly upgrade prompt when the backend rejects a create with 403
// (free-tier limit reached). Returns true if it handled a limit response.
async function handleLimit(res, label) {
  if (res.status !== 403) return false;
  let used, limit;
  try {
    const body = await res.json();
    ({ used, limit } = body.detail || {});
  } catch {}
  message.warning(
    limit != null
      ? `Free plan limit reached (${label}: ${used}/${limit} this week). Upgrade for unlimited access.`
      : `You've reached your free plan limit for ${label}. Upgrade for unlimited access.`
  );
  return true;
}

function normalizeNote(n, username = '') {
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

// Compliance sweep, optimization #4 -- applyFilter's notes are already in
// memory client-side (allNotes/groupNotes/notesCache); round-tripping them
// through POST /filter/ and POST /sort/ just to re-derive the same
// predicate the backend already applies is pure overhead. These two
// functions mirror api/backend/filters/filter_notes.py's Filters/Sorting
// classes exactly (same predicates, same nested-dict shape in/out) so a
// caller gets identical results without the network round trip.
function localFilterNotes(notes, toFilter) {
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
      (result[uid] ??= {})[nid] = note;
    }
  }
  return result;
}

// `descending`: true = newest first, matching Sorting.sort_date's
// `reverse=descending`. An unparseable timestamp sorts as the oldest
// possible value, matching the backend's datetime.min fallback.
function localSortNotesByDate(flatNotes, descending) {
  const withDates = Object.entries(flatNotes).map(([nid, note]) => {
    const t = Date.parse(note.timestamp);
    return [nid, Number.isNaN(t) ? -Infinity : t];
  });
  withDates.sort((a, b) => (descending ? b[1] - a[1] : a[1] - b[1]));

  const sorted = {};
  for (const [nid] of withDates) sorted[nid] = flatNotes[nid];
  return sorted;
}

export function useNotes({ user, curBook, curChapter, vsValue }) {
  const [allNotes,        setAllNotes]        = useState({});
  const [groupNotes,      setGroupNotes]      = useState({});
  const [currentGroupId,  setCurrentGroupId]  = useState(null);
  const [groups,          setGroups]          = useState([]);
  const [filteredNotes,   setFilteredNotes]   = useState(null);
  const [filteredGroup,   setFilteredGroup]   = useState(null);
  const [filterActive,    setFilterActive]    = useState(false);
  const [groupLoading,    setGroupLoading]    = useState(false);
  const notesCache = useRef({});
  // H13 (compliance sweep) -- client-side dedup for loadGroups' N+1
  // fetch-per-group pattern, mirroring useMessaging.js's friendCache/
  // groupEntryCache. Keyed by group id, populated once and reused on any
  // later loadGroups() call so an already-resolved group's title isn't
  // re-fetched. A real batched endpoint (this task's own deferred H13
  // follow-up, see intake-spec.md's Open Questions) would additionally let
  // this share results with useMessaging.js's own per-group cache instead
  // of each hook fetching/caching independently.
  const groupMetaCache = useRef({});

  // ── Load ──────────────────────────────────────────────────────────────────

  const loadNotes = useCallback(async () => {
    if (!user) return;
    try {
      const res = await fetch(`${API}/notes/${user.user_id}`);
      if (!res.ok) return;
      const payload = await res.json();
      // Backend now returns one keyset-paginated page as
      // {notes, next_cursor_created_at, next_cursor_id, has_more} instead of
      // a bare {note_id: note} dict -- unwrap .notes so this hook's own
      // shape (and every existing consumer of allNotes) is unaffected. The
      // web UI intentionally keeps its current full-list loading behavior
      // (no "load more" here) and just always sees the first capped page.
      // unwrapNotesEnvelope also fails safe (empty, not the raw envelope) if
      // .notes is ever missing or malformed -- see its doc comment.
      const data = unwrapNotesEnvelope(payload);
      setAllNotes(data);
      notesCache.current[''] = data;
    } catch (err) {
      console.error('Failed to load notes:', err);
    }
  }, [user]);

  const loadGroupNotes = useCallback(async (groupId) => {
    if (!user || !groupId) return;
    setGroupLoading(true);
    try {
      const res = await fetch(`${API}/groups/${user.user_id}/${groupId}/notes`);
      if (res.ok) {
        const payload = await res.json();
        // Same envelope unwrap as loadNotes above -- {username: {note_id: note}}
        // now lives under payload.notes.
        const data = unwrapNotesEnvelope(payload);
        setGroupNotes(data);
        notesCache.current[groupId] = data;
      }
    } catch (err) {
      console.error('Failed to load group notes:', err);
    }
    setGroupLoading(false);
  }, [user]);

  const loadGroups = useCallback(async () => {
    if (!user) return;
    try {
      const res = await fetch(`${API}/user/${user.user_id}`);
      if (!res.ok) return;
      const data = await res.json();
      const groupList = await Promise.all((data.groups || []).map(async gid => {
        if (groupMetaCache.current[gid]) return groupMetaCache.current[gid];
        try {
          const r = await fetch(`${API}/groups/${user.user_id}/${gid}`);
          if (r.ok) {
            const d = await r.json();
            const entry = { id: gid, title: d.group?.title || gid.slice(0, 8) };
            groupMetaCache.current[gid] = entry;
            return entry;
          }
        } catch (err) {
          console.error(`Failed to load group ${gid}:`, err);
        }
        return { id: gid, title: gid.slice(0, 8) };
      }));
      setGroups(groupList);
    } catch (err) {
      console.error('Failed to load groups:', err);
    }
  }, [user]);

  const selectGroup = useCallback(async (groupId, onHighlightsNeeded) => {
    try { localStorage.setItem('fs_notes_group', groupId || ''); } catch {}
    setCurrentGroupId(groupId || null);
    // Show cached data immediately while the fresh fetch runs in the background
    setGroupNotes(groupId ? (notesCache.current[groupId] || {}) : {});
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
      if (await handleLimit(res, 'notes')) return false;
      if (!res.ok) {
        if (res.status === 422) {
          let detail;
          try { ({ detail } = await res.json()); } catch {}
          message.error(detail || 'That note could not be saved. Please revise and try again.');
        }
        return false;
      }
      const saved = await res.json();
      const savedId = editingId || saved.id;
      if (noteData.group_id) {
        setAllNotes(prev => { const n = { ...prev }; delete n[savedId]; return n; });
        await loadGroupNotes(noteData.group_id);
      } else {
        setAllNotes(prev => ({ ...prev, [savedId]: noteData }));
      }
      return true;
    } catch (err) {
      console.error('Failed to save note:', err);
      message.error('Could not save your note. Check your connection and try again.');
      return false;
    }
  }, [user, loadGroupNotes]);

  const deleteNote = useCallback(async (id) => {
    if (!user) return;
    try {
      const res = await fetch(`${API}/notes/${user.user_id}?note_id=${encodeURIComponent(id)}`, { method: 'DELETE' });
      if (!res.ok) {
        message.error('Could not delete that note. Please try again.');
        return;
      }
      // The backend's own GET /notes/{user_id} filters to group_id IS NULL,
      // so a group note is never present in allNotes to begin with --
      // looking up its group_id there always misses, and the group's note
      // list silently never refreshed after a delete. groupNotes (loaded
      // for whichever group is currently selected) is the only place a
      // group note's data actually lives client-side, so check there too,
      // scoped to the currently selected group tab.
      let deletedGroupId = allNotes[id]?.group_id || null;
      if (!deletedGroupId && currentGroupId) {
        const inCurrentGroup = Object.values(groupNotes).some(notes => notes[id]);
        if (inCurrentGroup) deletedGroupId = currentGroupId;
      }
      setAllNotes(prev => { const n = { ...prev }; delete n[id]; return n; });
      if (deletedGroupId) {
        setGroupNotes(prev => {
          const next = {};
          for (const [uname, notes] of Object.entries(prev)) {
            const { [id]: _removed, ...rest } = notes;
            next[uname] = rest;
          }
          return next;
        });
        await loadGroupNotes(deletedGroupId);
      }
    } catch (err) {
      console.error('Failed to delete note:', err);
      message.error('Could not delete that note. Check your connection and try again.');
    }
  }, [user, allNotes, groupNotes, currentGroupId, loadGroupNotes]);

  const postReply = useCallback(async (noteId, text) => {
    if (!user || !currentGroupId || !text) return false;
    try {
      const res = await fetch(`${API}/notes/reply/${noteId}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          // Deny-by-default (Security Posture Q2): `public` now controls
          // group-edit permission, not visibility -- every reply is already
          // visible to the whole group via its inherited group_id, so there
          // is no reason to default this open.
          user: user.user_id, text, title: '', public: false,
          group_id: currentGroupId, replies: [], verses: [[], []], is_reply: true,
        }),
      });
      if (await handleLimit(res, 'notes')) return false;
      if (!res.ok) message.error('Could not post your reply. Please try again.');
      return res.ok;
    } catch (err) {
      console.error('Failed to post reply:', err);
      message.error('Could not post your reply. Check your connection and try again.');
      return false;
    }
  }, [user, currentGroupId]);

  const loadDetailReplies = useCallback(async (noteId) => {
    if (!user || !currentGroupId) return [];
    try {
      const res = await fetch(`${API}/groups/${user.user_id}/${noteId}/${currentGroupId}/replies`);
      if (res.ok) return await res.json();
    } catch (err) {
      console.error('Failed to load note replies:', err);
    }
    return [];
  }, [user, currentGroupId]);

  // ── Filter / sort ─────────────────────────────────────────────────────────

  const applyFilter = useCallback(({ sortVal, filterType, filterVal, activeTab }) => {
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

      // Compliance sweep, optimization #4 -- notes here are already fully
      // in memory (allNotes/groupNotes/notesCache above), so filter/sort is
      // done locally via localFilterNotes/localSortNotesByDate instead of
      // round-tripping through POST /filter/ and POST /sort/.
      let result = payload;
      if (hasFilter) result = localFilterNotes(result, toFilter);

      if (hasSort) {
        const flatNotes = {}, noteToUser = {};
        for (const [key, notes] of Object.entries(result)) {
          for (const [nid, data] of Object.entries(notes)) {
            flatNotes[nid] = data; noteToUser[nid] = key;
          }
        }
        const sortedFlat = localSortNotesByDate(flatNotes, toSort.date);
        const sortedResult = {};
        for (const [nid, data] of Object.entries(sortedFlat)) {
          const key = noteToUser[nid];
          if (!sortedResult[key]) sortedResult[key] = {};
          sortedResult[key][nid] = data;
        }
        result = sortedResult;
      }

      if (isGroupTab) {
        setFilteredGroup(result);
        setFilteredNotes(null);
      } else {
        setFilteredNotes(result[user.user_id] || {});
        setFilteredGroup(null);
      }
      setFilterActive(true);
    } catch (err) {
      console.error('Failed to apply filter/sort:', err);
    }
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
    allNotes, groupNotes, currentGroupId, groups, groupLoading,
    filteredNotes, filteredGroup, filterActive,
    loadNotes, loadGroupNotes, loadGroups, selectGroup,
    saveNote, deleteNote, postReply, loadDetailReplies,
    applyFilter, clearFilter, getNoteRef, getVerse,
  };
}
