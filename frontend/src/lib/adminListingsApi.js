// Thin wrappers over the admin listing-moderation endpoints
// (api/routes/explorer_admin.py). Every function throws AdminListingsApiError
// on a non-2xx or network failure. Admin authz is enforced server-side; these
// calls are only reachable behind AdminGate.
import { API } from '../config.js';

export class AdminListingsApiError extends Error {
  constructor(message, status) {
    super(message);
    this.name = 'AdminListingsApiError';
    this.status = status;
  }
}

async function request(path, options, fallback) {
  let res;
  try {
    res = await fetch(`${API}${path}`, options);
  } catch {
    throw new AdminListingsApiError('Could not reach the server.', 0);
  }
  if (!res.ok) {
    let message = fallback;
    let code;
    try {
      const d = await res.json();
      const detail = d?.detail;
      if (typeof detail === 'string') message = detail;
      else if (typeof detail?.message === 'string') message = detail.message;
      if (typeof detail?.code === 'string') code = detail.code;
    } catch { /* keep fallback */ }
    const e = new AdminListingsApiError(message, res.status);
    e.code = code;
    throw e;
  }
  return res.json();
}

const post = (body) => ({
  method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}),
});

export const QUEUE_STATUSES = ['pending_review', 'published', 'hidden', 'rejected'];
export const REJECT_REASONS = ['inappropriate', 'not_adults_only', 'misleading', 'spam', 'duplicate', 'incomplete', 'other'];
export const HIDE_REASONS = ['inappropriate', 'not_adults_only', 'misleading', 'spam', 'reported', 'other'];

export function fetchQueue(status) {
  return request(`/admin/explorer/listings/queue?status=${encodeURIComponent(status)}&limit=100`, undefined, "Couldn't load listings.");
}
const base = (id) => `/admin/explorer/listings/${encodeURIComponent(id)}`;
export const approveListing = (id) => request(`${base(id)}/approve`, post(), "Couldn't approve the listing.");
export const rejectListing = (id, reason) => request(`${base(id)}/reject`, post({ reason_code: reason }), "Couldn't reject the listing.");
export const hideListing = (id, reason) => request(`${base(id)}/hide`, post({ reason_code: reason }), "Couldn't hide the listing.");
export const restoreListing = (id) => request(`${base(id)}/restore`, post(), "Couldn't restore the listing.");
export const removeListing = (id) => request(base(id), { method: 'DELETE' }, "Couldn't delete the listing.");
