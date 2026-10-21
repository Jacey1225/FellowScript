import { useState, useEffect, useCallback } from 'react';

// Device-local collapsed state for ContactsPanel sections, keyed per user id.
// Everything is expanded by default; storage failures degrade to in-memory state.
export function collapsedStorageKey(userId) {
  return `fs.contacts.collapsed.${userId || 'anon'}`;
}

function read(userId) {
  try {
    const raw = window.localStorage.getItem(collapsedStorageKey(userId));
    const parsed = raw ? JSON.parse(raw) : {};
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch { return {}; }
}

export function useCollapsedSections(userId) {
  const [state, setState] = useState(() => read(userId));
  useEffect(() => { setState(read(userId)); }, [userId]);
  const toggle = useCallback((key) => {
    setState(prev => {
      const next = { ...prev, [key]: !prev[key] };
      try { window.localStorage.setItem(collapsedStorageKey(userId), JSON.stringify(next)); } catch { /* ignore */ }
      return next;
    });
  }, [userId]);
  return [state, toggle];
}
