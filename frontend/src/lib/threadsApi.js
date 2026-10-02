// Task 20261001-message-threads step 8. Thin clients for the threads and
// message-delete routes (api/routes/threads.py, api/routes/messages_delete.py)
// plus the small pure helpers the web client needs. Every function throws a
// ThreadsApiError on any non-2xx or network failure (throw-not-fabricate); the
// error carries the HTTP `status` (0 for a network failure) and the server's
// machine `code` when it sent one (e.g. terms_reaccept_required, thread_limit).
import { API } from '../config.js';
import { pageQuery } from './chatPaging.js';

export const THREAD_LIST_LIMIT = 20;
export const DEFAULT_UNDO_SECONDS = 10;

export class ThreadsApiError extends Error {
  constructor(message, status, code) {
    super(message);
    this.name = 'ThreadsApiError';
    this.status = status;
    this.code = code || null;
  }
}

async function request(path, options, fallback) {
  let res;
  try {
    res = await fetch(`${API}${path}`, options);
  } catch (err) {
    throw new ThreadsApiError('Could not reach the server.', 0, null);
  }
  if (!res.ok) {
    let message = fallback;
    let code = null;
    try {
      const d = await res.json();
      const detail = d && d.detail;
      if (typeof detail === 'string') message = detail;
      else if (detail && typeof detail === 'object') {
        if (typeof detail.code === 'string') code = detail.code;
        if (typeof detail.message === 'string') message = detail.message;
      }
    } catch (err) {
      // Non-JSON error body: keep the fallback copy.
    }
    throw new ThreadsApiError(message, res.status, code);
  }
  if (res.status === 204) return {};
  return res.json();
}

const base = (userId, groupId) => `/groups/${encodeURIComponent(userId)}/${encodeURIComponent(groupId)}`;

// One page of the group's threads (newest activity first). The cursor is
// { timestamp, id } (the list has no seq). Resolves to
// { threads, hasMore, cursor }.
export async function listThreads(userId, groupId, cursor = null) {
  const qs = pageQuery(THREAD_LIST_LIMIT, cursor ? { timestamp: cursor.timestamp, seq: null, id: cursor.id } : null);
  const data = await request(`${base(userId, groupId)}/threads?${qs}`, undefined, "Couldn't load threads.");
  return parseThreadsPage(data);
}

export function parseThreadsPage(data) {
  const threads = Array.isArray(data && data.threads) ? data.threads.filter(t => t && typeof t.id === 'string') : [];
  const page = (data && data.page) || {};
  const hasMore = page.has_more === true
    && typeof page.next_cursor_timestamp === 'string' && typeof page.next_cursor_id === 'string';
  return {
    threads,
    hasMore,
    cursor: hasMore ? { timestamp: page.next_cursor_timestamp, id: page.next_cursor_id } : null,
  };
}

// Start (or open the existing) thread on a main-chat message. Resolves to the
// thread summary {id, title, root_preview, root_message_id, root_deleted, ...}.
export function createThread(userId, groupId, messageId) {
  return request(`${base(userId, groupId)}/threads`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ message_id: messageId }),
  }, "Couldn't start a thread on that message.");
}

export function fetchThreadMessagesUrl(userId, groupId, threadId, limit, cursor) {
  return `${API}${base(userId, groupId)}/threads/${encodeURIComponent(threadId)}/messages?${pageQuery(limit, cursor)}`;
}

// Soft-delete the caller's own main-chat message. Resolves to { id, undo_seconds }.
export function deleteGroupMessage(userId, groupId, messageId) {
  return request(`${base(userId, groupId)}/messages/${encodeURIComponent(messageId)}`,
    { method: 'DELETE' }, "Couldn't delete that message. Please try again.");
}

// Undo within the undo window. Resolves to { id }.
export function restoreGroupMessage(userId, groupId, messageId) {
  return request(`${base(userId, groupId)}/messages/${encodeURIComponent(messageId)}/restore`,
    { method: 'POST' }, "Couldn't undo that delete.");
}

// Insert a restored (or rolled-back) message at its time position. Skips the
// insert when a row with the same id is already present. Timestamps from
// legacy and paged rows both parse with Date.parse; a row that cannot be
// placed goes to the end.
export function insertRestored(current, msg) {
  if (msg.id && current.some(m => m.id === msg.id)) return current;
  const t = Date.parse(msg.timestamp);
  if (Number.isNaN(t)) return [...current, msg];
  const idx = current.findIndex(m => {
    const mt = Date.parse(m.timestamp);
    return !Number.isNaN(mt) && mt > t;
  });
  if (idx === -1) return [...current, msg];
  return [...current.slice(0, idx), msg, ...current.slice(idx)];
}

export function relativeTime(ts, now = Date.now()) {
  const t = Date.parse(ts);
  if (Number.isNaN(t)) return '';
  const s = Math.max(0, Math.round((now - t) / 1000));
  if (s < 60) return 'just now';
  const m = Math.round(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h}h ago`;
  const d = Math.round(h / 24);
  if (d < 30) return `${d}d ago`;
  return new Date(t).toLocaleDateString([], { month: 'short', day: 'numeric' });
}
