// Task 20261001-promo-owner-rewards. Thin wrappers over the owner-reward and
// admin creator-code endpoints (api/routes/promo.py). Every function throws
// OwnerRewardsApiError on any non-2xx or network failure (throw-not-fabricate).
// A 404 is the backend's uniform "feature off / not found" answer; callers that
// can hide themselves check `err.status === 404`. Nothing here grants a
// discount or reward: the server decides everything and admin authz is
// enforced server-side (these calls are only reachable behind AdminGate).
import { API } from '../config.js';

export class OwnerRewardsApiError extends Error {
  constructor(message, status) {
    super(message);
    this.name = 'OwnerRewardsApiError';
    this.status = status;
  }
}

async function request(path, options, fallback) {
  let res;
  try {
    res = await fetch(`${API}${path}`, options);
  } catch {
    throw new OwnerRewardsApiError('Could not reach the server.', 0);
  }
  if (!res.ok) {
    let message = fallback;
    try {
      const d = await res.json();
      if (typeof d?.detail === 'string') message = d.detail;
    } catch { /* keep fallback */ }
    throw new OwnerRewardsApiError(message, res.status);
  }
  return res.json();
}

const json = (method, body) => ({
  method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
});

// Admin: create a creator + code attached to ownerEmail. `code` omitted ->
// the server generates a secure random one. Resolves { creator, code }.
export function createCreatorCode({ name, notes, ownerEmail, code, maxRedemptions, expiresAt }) {
  const body = { name, notes: notes || '', owner_email: ownerEmail };
  if (code) body.code = code;
  if (maxRedemptions) body.max_redemptions = maxRedemptions;
  if (expiresAt) body.expires_at = expiresAt;
  return request('/admin/promo/creator-codes', json('POST', body), "Couldn't create the code.");
}

// Admin: codes with attached email, redemption and reward counts.
export function listCodesOverview({ kind, limit = 100, offset = 0 } = {}) {
  const qs = new URLSearchParams({ limit: String(limit), offset: String(offset) });
  if (kind) qs.set('kind', kind);
  return request(`/admin/promo/codes-overview?${qs}`, undefined, "Couldn't load codes.");
}

// Admin: idempotent deactivate.
export function deactivateCode(codeId) {
  return request(`/admin/promo/codes/${encodeURIComponent(codeId)}/deactivate`, { method: 'POST' }, "Couldn't deactivate the code.");
}

// User: { percent_off, earned, claimed, expired, next_expiry, provider, can_claim_apple, ... }.
export function fetchRewardSummary(userId) {
  return request(`/rewards/${encodeURIComponent(userId)}`, undefined, "Couldn't load your rewards.");
}
