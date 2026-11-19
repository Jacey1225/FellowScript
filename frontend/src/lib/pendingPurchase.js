// Task 20261118-public-membership-page: the membership purchase intent
// (seat count) a signed-out visitor carried to /membership, kept across the
// sign-in / sign-up / verify / 2FA redirects. Modeled on pendingInvite.js:
// sessionStorage only (this tab), seats + timestamp only, 24h expiry,
// cleared on sign-out. Nothing here is a secret and nothing is a URL: the
// stored value is an integer, re-validated on every read, so no redirect
// target can ever be injected through it.
import { SEAT_PRICING } from './seatPricing.js';
import { isDesktopApp } from './desktopScope.js';

const KEY = 'fs_pending_purchase';
export const PENDING_PURCHASE_TTL_MS = 24 * 60 * 60 * 1000;

// Parse a seats param (string from a URL, or a number) into a whole number
// clamped to the server's range; anything non-numeric falls back to the
// minimum. This is a UX prefill only: the server re-validates and re-prices.
export function clampSeats(value) {
  const n = typeof value === 'number' ? value : (/^\d{1,4}$/.test(String(value ?? '')) ? Number(value) : NaN);
  if (!Number.isInteger(n)) return SEAT_PRICING.minMembers;
  return Math.min(SEAT_PRICING.maxMembers, Math.max(SEAT_PRICING.minMembers, n));
}

// Fixed, internal route; only the clamped integer is interpolated.
export function membershipPath(seats) {
  return `/membership?seats=${clampSeats(seats)}`;
}

export function setPendingPurchase(seats, now = Date.now()) {
  try { sessionStorage.setItem(KEY, JSON.stringify({ seats: clampSeats(seats), at: now })); } catch { /* storage blocked */ }
}

export function getPendingPurchase(now = Date.now()) {
  let stored;
  try {
    stored = JSON.parse(sessionStorage.getItem(KEY) || 'null');
  } catch {
    stored = null;
  }
  if (!stored || !Number.isInteger(stored.seats) || typeof stored.at !== 'number' || now - stored.at > PENDING_PURCHASE_TTL_MS) {
    try { sessionStorage.removeItem(KEY); } catch { /* ignore */ }
    return null;
  }
  return { seats: clampSeats(stored.seats) };
}

export function clearPendingPurchase() {
  try { sessionStorage.removeItem(KEY); } catch { /* ignore */ }
}

// Non-desktop web has no reader (/reader sends browsers to /download), so the
// "nothing better to do" landing for a web user is Home, never /reader.
export function webSafeReaderPath() {
  return isDesktopApp() ? '/reader' : '/';
}
