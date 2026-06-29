import { useState, useCallback } from 'react';
import { API } from '../config.js';

export function useBookmarks({ user }) {
  const [bookmarks, setBookmarks] = useState({});

  const loadBookmarks = useCallback(async () => {
    if (!user) return;
    try {
      const res = await fetch(`${API}/notes/bookmark/${user.user_id}`);
      if (res.ok) setBookmarks(await res.json());
    } catch {}
  }, [user]);

  const addBookmark = useCallback(async (book, chapter, label = '') => {
    if (!user || !book || !chapter) return;
    const key = `${book}-${chapter}`;
    setBookmarks(prev => ({ ...prev, [key]: label }));
    try {
      await fetch(`${API}/notes/bookmark/${user.user_id}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ book, chapter, label }),
      });
    } catch {}
  }, [user]);

  const removeBookmark = useCallback(async (key) => {
    if (!user) return;
    setBookmarks(prev => { const n = { ...prev }; delete n[key]; return n; });
    try {
      await fetch(
        `${API}/notes/bookmark/${user.user_id}/${encodeURIComponent(key)}`,
        { method: 'DELETE' }
      );
    } catch {}
  }, [user]);

  return { bookmarks, loadBookmarks, addBookmark, removeBookmark };
}
