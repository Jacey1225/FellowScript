// Thin wrappers over the admin home-announcement endpoints
// (api/routes/home_messages.py). Every function throws AdminHomeMessagesApiError
// on a non-2xx or network failure. Admin authz is enforced server-side.
import { API } from '../config.js';

export class AdminHomeMessagesApiError extends Error {
  constructor(message, status) {
    super(message);
    this.name = 'AdminHomeMessagesApiError';
    this.status = status;
  }
}

async function request(path, options, fallback) {
  let res;
  try {
    res = await fetch(`${API}${path}`, options);
  } catch {
    throw new AdminHomeMessagesApiError('Could not reach the server.', 0);
  }
  if (!res.ok) {
    let message = fallback;
    if (res.status === 429) message = 'Too many requests. Wait a moment and try again.';
    try {
      const d = await res.json();
      const detail = d?.detail;
      if (typeof detail === 'string') message = detail;
      else if (typeof detail?.message === 'string') message = detail.message;
    } catch { /* keep fallback */ }
    throw new AdminHomeMessagesApiError(message, res.status);
  }
  return res.json();
}

const JSON_HEADERS = { 'Content-Type': 'application/json' };
const one = (id) => `/admin/home-messages/${encodeURIComponent(id)}`;

// -> { items: [{id,text,enabled,priority,starts_at,ends_at,destination,created_at,updated_at}], text_max_length, max_enabled }
export const listHomeMessages = () =>
  request('/admin/home-messages', undefined, "Couldn't load announcements.");

export const createHomeMessage = ({ text, priority = 0 }) =>
  request('/admin/home-messages', {
    method: 'POST', headers: JSON_HEADERS, body: JSON.stringify({ text, priority, enabled: false }),
  }, "Couldn't add the announcement.");

export const setHomeMessageEnabled = (id, enabled) =>
  request(one(id), {
    method: 'PATCH', headers: JSON_HEADERS, body: JSON.stringify({ enabled }),
  }, "Couldn't update the announcement.");

export const deleteHomeMessage = (id) =>
  request(one(id), { method: 'DELETE' }, "Couldn't delete the announcement.");
