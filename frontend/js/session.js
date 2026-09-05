// Session persistence: save/validate server sessions, persist user across tabs.

import { API } from './config.js';

const STORAGE_KEY = 'fs_user';

export function persistUser(userData) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(userData));
}

export function clearPersistedUser() {
  localStorage.removeItem(STORAGE_KEY);
  sessionStorage.removeItem('user');
}

export async function saveSession(userId, lastPage = '') {
  if (!userId) return;
  try {
    const res = await fetch(`${API}/session/`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ user_id: userId, last_page: lastPage }),
    });
    if (!res.ok) console.warn('[session] saveSession failed', userId, res.status);
  } catch (err) { console.error('[session] saveSession error:', userId, err); }
}

// Returns session object { user_id, last_page, last_login, expiration } if valid,
// null if expired/not found, or undefined if the server was unreachable (offline).
export async function validateSession(userId) {
  if (!userId) return null;
  try {
    const res = await fetch(`${API}/session/${userId}`);
    if (!res.ok) { console.warn('[session] validateSession failed', userId, res.status); return null; }
    const data = await res.json();
    if (data.error) return null;
    return data.success;
  } catch (err) {
    console.error('[session] validateSession error:', userId, err);
    return undefined; // undefined = offline, don't log out
  }
}
