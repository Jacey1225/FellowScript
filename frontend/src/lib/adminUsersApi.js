// Thin wrappers over the admin user-actions endpoints (api/routes/admin_users.py).
// Every function throws AdminUsersApiError on a non-2xx or network failure.
// Admin authz is enforced server-side; these calls are only reachable behind AdminGate.
import { API } from '../config.js';

export class AdminUsersApiError extends Error {
  constructor(message, status) {
    super(message);
    this.name = 'AdminUsersApiError';
    this.status = status;
  }
}

async function request(path, options, fallback) {
  let res;
  try {
    res = await fetch(`${API}${path}`, options);
  } catch {
    throw new AdminUsersApiError('Could not reach the server.', 0);
  }
  if (!res.ok) {
    let message = fallback;
    let code;
    if (res.status === 429) message = 'Too many requests. Wait a moment and try again.';
    try {
      const d = await res.json();
      const detail = d?.detail;
      if (typeof detail === 'string') message = detail;
      else if (typeof detail?.message === 'string') message = detail.message;
      if (typeof detail?.code === 'string') code = detail.code;
    } catch { /* keep fallback */ }
    const e = new AdminUsersApiError(message, res.status);
    e.code = code;
    throw e;
  }
  return res.json();
}

export function fetchUsers({ q, page } = {}) {
  const p = new URLSearchParams();
  if (q) p.set('q', q);
  p.set('page', String(page || 1));
  return request(`/admin/users?${p.toString()}`, undefined, "Couldn't load users.");
}

const base = (id) => `/admin/users/${encodeURIComponent(id)}`;
export const grantAdmin = (id) => request(`${base(id)}/grant-admin`, { method: 'POST' }, "Couldn't grant admin.");
export const revokeAdmin = (id) => request(`${base(id)}/revoke-admin`, { method: 'POST' }, "Couldn't revoke admin.");
