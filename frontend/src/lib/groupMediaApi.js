// Task 20261023-group-info-row. Client for GET /groups/{user_id}/{group_id}/media
// (api/routes, flag `group_media`, default OFF). Same contract as threadsApi.js:
// throws a GroupMediaError on any non-2xx, network failure or undecodable body
// (throw-not-fabricate); callers keep the last good list on a failed refresh.
import { API } from '../config.js';
import { pageQuery } from './chatPaging.js';

export const MEDIA_FEATURE = 'group_media';
export const MEDIA_PAGE_LIMIT = 30;
export const MEDIA_KINDS = ['image', 'video', 'gif'];

export class GroupMediaError extends Error {
  constructor(message, status) {
    super(message);
    this.name = 'GroupMediaError';
    this.status = status;
  }
}

const base = (userId, groupId) => `/groups/${encodeURIComponent(userId)}/${encodeURIComponent(groupId)}`;

// One media item from the wire -> the shape the grid renders, or null when the
// row is unusable (no message id or an unknown kind).
export function parseMediaItem(raw) {
  if (!raw || typeof raw.message_id !== 'string' || !MEDIA_KINDS.includes(raw.kind)) return null;
  const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
  const str = (v) => (typeof v === 'string' && v ? v : null);
  return {
    messageId: raw.message_id,
    kind: raw.kind,
    thumbUrl: str(raw.thumb_url),
    url: str(raw.url),
    width: num(raw.width),
    height: num(raw.height),
    duration: num(raw.duration),
    senderId: str(raw.sender_id),
    senderName: str(raw.sender_name) || 'Someone',
    createdAt: str(raw.created_at),
  };
}

// -> { items, hasMore, cursor } where cursor is { timestamp, seq, id } | null.
export function parseMediaPage(data) {
  if (!data || !Array.isArray(data.media)) return null;
  const items = data.media.map(parseMediaItem).filter(Boolean);
  const page = data.page || {};
  const hasMore = page.has_more === true
    && typeof page.next_cursor_timestamp === 'string' && typeof page.next_cursor_id === 'string';
  return {
    items,
    hasMore,
    cursor: hasMore
      ? { timestamp: page.next_cursor_timestamp, seq: page.next_cursor_seq ?? null, id: page.next_cursor_id }
      : null,
  };
}

export async function fetchGroupMedia(userId, groupId, cursor = null, limit = MEDIA_PAGE_LIMIT) {
  const qs = `${pageQuery(limit, cursor)}&kind=${MEDIA_KINDS.join(',')}`;
  let res;
  try {
    res = await fetch(`${API}${base(userId, groupId)}/media?${qs}`, { credentials: 'include' });
  } catch (err) {
    throw new GroupMediaError('Could not reach the server.', 0);
  }
  if (!res.ok) throw new GroupMediaError("Couldn't load media.", res.status);
  let body = null;
  try { body = await res.json(); } catch (err) { /* handled below */ }
  const parsed = parseMediaPage(body);
  if (!parsed) throw new GroupMediaError("Couldn't load media.", res.status);
  return parsed;
}

// Column count by the panel's own width (design-spec section 4).
export function mediaColumns(width) {
  if (width >= 900) return 5;
  if (width >= 600) return 4;
  return 3;
}

export function mediaCellLabel(item, when) {
  const noun = item.kind === 'video' ? 'Video' : item.kind === 'gif' ? 'GIF' : 'Photo';
  return `${noun} from ${item.senderName}${when ? `, ${when}` : ''}`;
}

// "Oct 19, 2026 at 7:55 PM"
export function fullDateTime(ts) {
  if (!ts) return '';
  const d = new Date(ts);
  if (Number.isNaN(d.getTime())) return '';
  const date = d.toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' });
  const time = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  return `${date} at ${time}`;
}

export function formatDuration(sec) {
  if (typeof sec !== 'number' || !Number.isFinite(sec) || sec < 0) return '';
  const s = Math.round(sec);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}
