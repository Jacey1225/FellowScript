// Task 20260930-creator-friend-codes. Client helpers for promo (creator /
// friend invite) codes. Nothing here grants a discount: the server re-validates
// every code at checkout. This module only carries a shared ?code= link
// through sign-in/sign-up so the buyer does not have to retype it.
import { API } from '../config.js';

const STORAGE_KEY = 'fs_pending_promo_code';
const TTL_MS = 7 * 24 * 3600 * 1000;
const CODE_RE = /^[A-Za-z0-9_-]{1,64}$/;

export function normalizeCode(raw) {
  return (raw || '').trim().toUpperCase();
}

export function isWellFormedCode(raw) {
  return CODE_RE.test((raw || '').trim());
}

export function savePendingCode(raw, now = Date.now()) {
  if (!isWellFormedCode(raw)) return false;
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ code: normalizeCode(raw), at: now }));
    return true;
  } catch {
    return false;
  }
}

export function readPendingCode(now = Date.now()) {
  try {
    const parsed = JSON.parse(localStorage.getItem(STORAGE_KEY) || 'null');
    if (!parsed || typeof parsed.code !== 'string' || !isWellFormedCode(parsed.code)) return '';
    if (typeof parsed.at !== 'number' || now - parsed.at > TTL_MS) {
      localStorage.removeItem(STORAGE_KEY);
      return '';
    }
    return parsed.code;
  } catch {
    return '';
  }
}

export function clearPendingCode() {
  try { localStorage.removeItem(STORAGE_KEY); } catch { /* ignore */ }
}

// Run once before React mounts: capture ?code=XYZ from a shared link, remember
// it, and strip it from the address bar (the hash route is kept).
export function captureCodeFromUrl() {
  try {
    const params = new URLSearchParams(window.location.search);
    if (!params.has('code')) return;
    savePendingCode(params.get('code'));
    params.delete('code');
    const qs = params.toString();
    window.history.replaceState({}, '', window.location.pathname + (qs ? `?${qs}` : '') + window.location.hash);
  } catch { /* ignore */ }
}

// Server calls. validate answers 404 when the feature flag is off (the whole
// promo UI then stays hidden) and {valid:false} for every unusable code.
export async function validatePromoCode(userId, code, memberCount = 1) {
  try {
    const res = await fetch(`${API}/promo/${userId}/validate`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code, member_count: memberCount }),
    });
    if (res.status === 404) return { enabled: false, valid: false };
    if (res.status === 429) return { enabled: true, valid: false, limited: true };
    if (!res.ok) return { enabled: false, valid: false, failed: true };
    const data = await res.json().catch(() => ({}));
    return { enabled: true, valid: data.valid === true, percentOff: data.percent_off };
  } catch {
    return { enabled: false, valid: false, failed: true };
  }
}

export async function fetchFriendCode(userId) {
  const res = await fetch(`${API}/promo/${userId}/friend-code`, { method: 'POST' });
  if (!res.ok) throw new Error(`friend-code ${res.status}`);
  const data = await res.json();
  if (!data || typeof data.code !== 'string') throw new Error('friend-code malformed');
  return data;
}
