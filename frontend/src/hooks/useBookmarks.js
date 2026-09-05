import { useState, useCallback } from 'react';
import { message } from 'antd';
import { API } from '../config.js';

export function useBookmarks({ user }) {
  const [bookmarks, setBookmarks] = useState({});

  const loadBookmarks = useCallback(async () => {
    if (!user) return;
    try {
      const res = await fetch(`${API}/notes/bookmark/${user.user_id}`);
      if (res.ok) setBookmarks(await res.json());
    } catch (err) {
      // Background load -- log only, matching useMessaging.loadContacts'
      // established convention for passive/background loads.
      console.error('Failed to load bookmarks:', err);
    }
  }, [user]);

  const addBookmark = useCallback(async (book, chapter, label = '') => {
    if (!user || !book || !chapter) return;
    const key = `${book}-${chapter}`;
    const hadPrevious = Object.prototype.hasOwnProperty.call(bookmarks, key);
    const previous = bookmarks[key];
    setBookmarks(prev => ({ ...prev, [key]: label }));
    try {
      const res = await fetch(`${API}/notes/bookmark/${user.user_id}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ book, chapter, label }),
      });
      if (!res.ok) throw new Error(`Bookmark save failed with status ${res.status}`);
    } catch (err) {
      // Roll back the optimistic update rather than leaving state
      // permanently ahead of what the server actually has (Architecture
      // Q27), same standard as useNotes.js/useMessaging.js.
      console.error('Failed to add bookmark:', err);
      message.error('Could not save that bookmark. Check your connection and try again.');
      setBookmarks(prev => {
        const next = { ...prev };
        if (hadPrevious) next[key] = previous; else delete next[key];
        return next;
      });
    }
  }, [user, bookmarks]);

  const removeBookmark = useCallback(async (key) => {
    if (!user) return;
    const hadPrevious = Object.prototype.hasOwnProperty.call(bookmarks, key);
    const previous = bookmarks[key];
    setBookmarks(prev => { const n = { ...prev }; delete n[key]; return n; });
    try {
      const res = await fetch(
        `${API}/notes/bookmark/${user.user_id}/${encodeURIComponent(key)}`,
        { method: 'DELETE' }
      );
      if (!res.ok && res.status !== 204) throw new Error(`Bookmark delete failed with status ${res.status}`);
    } catch (err) {
      console.error('Failed to remove bookmark:', err);
      message.error('Could not remove that bookmark. Check your connection and try again.');
      if (hadPrevious) setBookmarks(prev => ({ ...prev, [key]: previous }));
    }
  }, [user, bookmarks]);

  return { bookmarks, loadBookmarks, addBookmark, removeBookmark };
}
