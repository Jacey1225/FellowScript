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

// Task 20261001-explorer-listings step 10: an Explore URL (for example the
// publish/manage page) a signed-out visitor was sent from, kept across the
// sign-in redirects so they return to it. Separate key from the invite token
// (an invite always wins). Only an in-app /explore path is ever stored, this
// tab only (sessionStorage), 24h expiry, consumed once on a successful sign-in.
const EXPLORE_KEY = 'fs_pending_explore';
const EXPLORE_PATH_RE = /^\/explore(\/[A-Za-z0-9_-]{1,32})?(\?[A-Za-z0-9_=&-]{0,120})?$/;

export function setPendingExplore(path, now = Date.now()) {
  if (typeof path !== 'string' || !EXPLORE_PATH_RE.test(path)) return;
  sessionStorage.setItem(EXPLORE_KEY, JSON.stringify({ path, at: now }));
}

export function getPendingExplore(now = Date.now()) {
  let stored;
  try {
    stored = JSON.parse(sessionStorage.getItem(EXPLORE_KEY) || 'null');
  } catch {
    stored = null;
  }
  if (!stored || typeof stored.path !== 'string' || !EXPLORE_PATH_RE.test(stored.path)
    || typeof stored.at !== 'number' || now - stored.at > PENDING_INVITE_TTL_MS) {
    sessionStorage.removeItem(EXPLORE_KEY);
    return null;
  }
  return stored.path;
}

export function clearPendingExplore() {
  sessionStorage.removeItem(EXPLORE_KEY);
}

// Where to land right after a successful sign-in / sign-up: back on the
// pending invite's screen when there is one, then a pending Explore page
// (consumed here), otherwise the reader.
export function postAuthPath() {
  const token = getPendingInvite();
  if (token) return `/join/${token}`;
  const explore = getPendingExplore();
  if (explore) {
    clearPendingExplore();
    return explore;
  }
  return '/reader';
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
