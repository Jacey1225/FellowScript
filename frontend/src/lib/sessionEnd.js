// Task 20261017-chat-ws-reconnect-stuck (web/desktop): detect an ended
// sign-in session and stop retrying against it.
//
// A browser WebSocket cannot read the handshake status, so a rejected
// (expired-session) handshake looks identical to a dropped network. The chat
// hooks therefore probe an authenticated endpoint when the socket closes:
// 401 means the session ended; anything else (success, 5xx, no network) keeps
// the normal capped-backoff reconnect.
//
// Also exposes one global latch fed by a fetch guard (installSessionGuard,
// called once from main.jsx) so a 401 on any authenticated call shows the same
// "session ended" state. Nothing here wipes local data or fabricates a result.
import { API } from '../config.js';

export const SESSION_ENDED_MESSAGE = 'Your session ended. Sign in again.';

// Endpoints that are legitimately called without a session, or whose 401 is a
// wrong-credential answer for a signed-in user (not a session failure).
const UNAUTHENTICATED_PATHS = [
  /^\/login\/?$/,
  /^\/signup(\/|$)/,
  /^\/logout\/?$/,
  /^\/auth\/google\/?$/,
  /^\/auth\/apple\/?$/,
  /^\/auth\/mfa\/verify-login\/?$/,
  /^\/auth\/mfa\/disable\/?$/,
  /^\/auth\/password-reset/,
  /^\/app\/capabilities\/?$/,
  /^\/invites\/preview/,
  /^\/explorer\/config\/?$/,
  /^\/explorer\/listings(\/|$)/,
];

export function isUnauthenticatedPath(path) {
  const p = String(path || '').split('?')[0];
  return UNAUTHENTICATED_PATHS.some((re) => re.test(p));
}

// url may be absolute (https://host/api/user/1) or relative to the API base.
export function apiPathOf(url, apiBase = API) {
  const u = String(url || '');
  if (u.startsWith(apiBase)) return u.slice(apiBase.length) || '/';
  try {
    const parsed = new URL(u, 'http://localhost');
    const base = new URL(apiBase, 'http://localhost');
    if (parsed.origin === base.origin && parsed.pathname.startsWith(base.pathname)) {
      return parsed.pathname.slice(base.pathname.replace(/\/$/, '').length) || '/';
    }
  } catch { /* fall through */ }
  return null; // not an API call
}

export function shouldMarkSessionEnded(status, url, apiBase = API) {
  if (status !== 401) return false;
  const path = apiPathOf(url, apiBase);
  return path !== null && !isUnauthenticatedPath(path);
}

// ── Latch + subscription (mark once; reset on sign-in / sign-out) ───────────
let ended = false;
const listeners = new Set();

export function isSessionEnded() { return ended; }

export function markSessionEnded() {
  if (ended) return false; // latched: a burst of 401s is handled once
  ended = true;
  listeners.forEach((cb) => cb());
  return true;
}

export function resetSessionEnded() {
  if (!ended) return;
  ended = false;
  listeners.forEach((cb) => cb());
}

export function subscribeSessionEnded(cb) {
  listeners.add(cb);
  return () => listeners.delete(cb);
}

// Probe the existing current-user call. Resolves 'ended' only on a definite
// 401; a thrown fetch, missing response, or any other status is 'alive'
// (transient), so the caller keeps reconnecting.
export async function probeSession(userId, fetchImpl = globalThis.fetch, apiBase = API) {
  try {
    const res = await fetchImpl(`${apiBase}/user/${userId}`, { credentials: 'include' });
    return res && res.status === 401 ? 'ended' : 'alive';
  } catch {
    return 'alive';
  }
}

// Reconnect delay: 3s doubling to a 30s cap (attempt is 1-based).
export function backoffDelay(attempt, minMs = 3000, maxMs = 30000) {
  return Math.min(minMs * 2 ** (Math.max(attempt, 1) - 1), maxMs);
}

let installed = false;
// Wrap window.fetch once so every authenticated call feeds the latch. The
// original response is returned untouched and callers still see the 401.
export function installSessionGuard(target = globalThis) {
  if (installed || typeof target.fetch !== 'function') return;
  installed = true;
  const original = target.fetch.bind(target);
  target.fetch = async (input, init) => {
    const res = await original(input, init);
    try {
      const url = typeof input === 'string' ? input : input?.url;
      if (res && shouldMarkSessionEnded(res.status, url)) markSessionEnded();
    } catch { /* never let the guard break a request */ }
    return res;
  };
}
