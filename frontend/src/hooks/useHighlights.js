import { useState, useCallback } from 'react';
import { API } from '../config.js';
import { hexWithAlpha } from '../utils.js';

export function useHighlights({ user, curBook, curChapter }) {
  const [localHl,         setLocalHl]         = useState({});
  const [groupHighlights, setGroupHighlights] = useState({});
  const [groupUsernames,  setGroupUsernames]  = useState({});

  const loadHighlights = useCallback(async () => {
    if (!user) return;
    try {
      const res = await fetch(`${API}/notes/highlight/${user.user_id}`);
      if (res.ok) setLocalHl(await res.json());
    } catch {}
  }, [user]);

  const applyHighlights = useCallback((containerEl) => {
    if (!containerEl) return;
    containerEl.querySelectorAll('.verse-span').forEach(el => {
      el.removeAttribute('data-hl');
      el.style.background = '';
      el.querySelectorAll('.hl-badge').forEach(b => b.remove());
    });

    Object.entries(localHl).forEach(([key, color]) => {
      const [book, ch, vs] = key.split('-');
      if (book === curBook && parseInt(ch) === curChapter) {
        const span = containerEl.querySelector(`#vs${vs}`);
        if (span) {
          span.dataset.hl      = color;
          span.style.background = hexWithAlpha(color, 0.28);
        }
      }
    });

    Object.entries(groupHighlights).forEach(([uid, highlights]) => {
      const uname   = groupUsernames[uid] || uid.slice(0, 3);
      const initial = uname[0].toUpperCase();
      Object.entries(highlights).forEach(([key, color]) => {
        const [book, ch, vs] = key.split('-');
        if (book === curBook && parseInt(ch) === curChapter) {
          const span = containerEl.querySelector(`#vs${vs}`);
          if (span) {
            if (!span.dataset.hl) span.style.background = hexWithAlpha(color, 0.2);
            const badge = document.createElement('span');
            badge.className        = 'hl-badge';
            badge.title            = uname;
            badge.style.background = color;
            badge.textContent      = initial;
            span.appendChild(badge);
          }
        }
      });
    });
  }, [localHl, groupHighlights, groupUsernames, curBook, curChapter]);

  const setHighlight = useCallback(async (verseNum, color) => {
    if (!user || !curBook || !curChapter) return;
    const key = `${curBook}-${curChapter}-${verseNum}`;
    setLocalHl(prev => ({ ...prev, [key]: color }));
    try {
      await fetch(`${API}/notes/highlight/${user.user_id}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ book: curBook, chapter: curChapter, verse: verseNum, color }),
      });
    } catch {}
  }, [user, curBook, curChapter]);

  const clearHighlight = useCallback(async (verseNum) => {
    if (!user || !curBook || !curChapter) return;
    const key = `${curBook}-${curChapter}-${verseNum}`;
    setLocalHl(prev => { const n = { ...prev }; delete n[key]; return n; });
    try {
      await fetch(`${API}/notes/highlight/${user.user_id}/${encodeURIComponent(key)}`, { method: 'DELETE' });
    } catch {}
  }, [user, curBook, curChapter]);

  const loadGroupHighlights = useCallback(async (groupId, friendCache = {}) => {
    if (!user) return;
    try {
      const res = await fetch(`${API}/groups/${user.user_id}/${groupId}/highlights`);
      if (!res.ok) return;
      const highlights = await res.json();
      const usernames  = {};
      await Promise.all(Object.keys(highlights).map(async uid => {
        if (uid === user.user_id) { usernames[uid] = user.username || 'Me'; return; }
        if (friendCache[uid])     { usernames[uid] = friendCache[uid]; return; }
        try {
          const r = await fetch(`${API}/user/${uid}`);
          if (r.ok) { const d = await r.json(); usernames[uid] = d.username || uid.slice(0, 4); }
        } catch { usernames[uid] = uid.slice(0, 4); }
      }));
      setGroupHighlights(highlights);
      setGroupUsernames(usernames);
    } catch {}
  }, [user]);

  const clearGroupHighlights = useCallback(() => {
    setGroupHighlights({});
    setGroupUsernames({});
  }, []);

  return {
    localHl, groupHighlights,
    loadHighlights, applyHighlights,
    setHighlight, clearHighlight,
    loadGroupHighlights, clearGroupHighlights,
  };
}
