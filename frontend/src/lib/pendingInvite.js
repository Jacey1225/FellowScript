// Task 20260929-group-invite-links (design-notes.md C): the invite token a
// signed-out visitor arrived with, kept across the sign-in / sign-up /
// 2FA redirects. Bearer-ish secret, so it lives in sessionStorage only (this
// tab, gone when the browser closes -- never localStorage), holds only the
// token string plus a timestamp, and expires after 24h. Consumed exactly
// once: callers clear it on success, on any terminal 4xx, on Cancel, and on
// sign-out. Newest link replaces any older pending one.
import { isWellFormedInviteToken } from './invitesApi.js';

const KEY = 'fs_pending_invite';
export const PENDING_INVITE_TTL_MS = 24 * 60 * 60 * 1000;

export function setPendingInvite(token, now = Date.now()) {
  if (!isWellFormedInviteToken(token)) return;
  sessionStorage.setItem(KEY, JSON.stringify({ token, at: now }));
}

export function getPendingInvite(now = Date.now()) {
  let stored;
  try {
    stored = JSON.parse(sessionStorage.getItem(KEY) || 'null');
  } catch {
    stored = null;
  }
  if (!stored || !isWellFormedInviteToken(stored.token) || typeof stored.at !== 'number' || now - stored.at > PENDING_INVITE_TTL_MS) {
    sessionStorage.removeItem(KEY);
    return null;
  }
  return stored.token;
}

export function clearPendingInvite() {
  sessionStorage.removeItem(KEY);
}

// Where to land right after a successful sign-in / sign-up: back on the
// pending invite's screen when there is one, otherwise the reader.
export function postAuthPath() {
  const token = getPendingInvite();
  return token ? `/join/${token}` : '/reader';
}

// Group to open in the reader right after a join (desktop). One-shot.
const OPEN_GROUP_KEY = 'fs_open_group';
export function setGroupToOpen(groupId) { sessionStorage.setItem(OPEN_GROUP_KEY, String(groupId)); }
export function takeGroupToOpen() {
  const id = sessionStorage.getItem(OPEN_GROUP_KEY);
  if (id) sessionStorage.removeItem(OPEN_GROUP_KEY);
  return id;
}
export function peekGroupToOpen() { return sessionStorage.getItem(OPEN_GROUP_KEY); }
