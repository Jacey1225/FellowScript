// Task 20261012-message-pins (web). Pinned messages client. Mirrors the
// backend contract in api/routes/message_pins.py. Throw-not-fabricate: any
// non-2xx, transport error or undecodable body throws a PinError; the caller
// rolls back its optimistic change and shows the warm message. No pin cap.
import { API } from '../config.js';

export const PIN_FEATURE = 'message_pins';
export const PIN_PAGE_LIMIT = 20;
export const PIN_FALLBACK = "That didn't go through. Please try again.";
export const PIN_RATE_COPY = 'Easy there. Give it a moment and try again.';
export const PIN_LIST_ERROR = "Couldn't load pinned messages. Try again?";
export const PIN_GONE_COPY = 'That message is no longer available.';
export const PIN_NOT_FOUND_COPY = "Couldn't find that message. It may have been removed.";

export class PinError extends Error {
  constructor(kind, message) {
    super(message);
    this.name = 'PinError';
    this.kind = kind; // unavailable | terms | rate | failed
  }
}

// History row / live frame -> the pin fields a chat message carries. `pinned`
// only exists while the flag is on for the viewer; `system_kind` marks the
// server-generated "X pinned a message" line.
export function pinFields(row) {
  const out = {};
  if (row && typeof row.pinned === 'boolean') out.pinned = row.pinned;
  if (row && row.system_kind === 'pin') out.systemKind = 'pin';
  return out;
}

// One entry of GET .../pins -> { messageId, pinnedBy, pinnedById, pinnedAt,
// message: { id, fromUserId, from, text, timestamp, attachmentKind } } or null.
export function parsePin(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const m = raw.message;
  if (typeof raw.message_id !== 'string' || !raw.message_id) return null;
  if (!m || typeof m !== 'object') return null;
  return {
    messageId: raw.message_id,
    pinnedBy: typeof raw.pinned_by === 'string' ? raw.pinned_by : '',
    pinnedById: typeof raw.pinned_by_id === 'string' ? raw.pinned_by_id : '',
    pinnedAt: typeof raw.pinned_at === 'string' ? raw.pinned_at : null,
    message: {
      id: raw.message_id,
      fromUserId: typeof m.from_user_id === 'string' ? m.from_user_id : '',
      from: typeof m.from_user === 'string' ? m.from_user : '',
      text: typeof m.text === 'string' ? m.text : '',
      timestamp: typeof m.timestamp === 'string' ? m.timestamp : null,
      attachmentKind: typeof m.attachment_kind === 'string' && m.attachment_kind ? m.attachment_kind : null,
    },
  };
}

// List body -> { pins, hasMore, count } or null when malformed.
export function parsePinList(body) {
  if (!body || typeof body !== 'object' || !Array.isArray(body.pins)) return null;
  const pins = body.pins.map(parsePin).filter(Boolean);
  const count = Number.isInteger(body.count) && body.count >= 0 ? body.count : pins.length;
  return { pins, hasMore: body.has_more === true, count };
}

const ATTACHMENT_LABEL = { image: 'Photo', video: 'Video', gif: 'GIF', file: 'File' };

// Row preview: the text, else the attachment label, never empty.
export function pinPreview(pin) {
  const t = (pin.message.text || '').trim();
  if (t) return t;
  return ATTACHMENT_LABEL[pin.message.attachmentKind] || 'Message';
}

export function pinnedByLabel(pin, viewerId) {
  const mine = viewerId && pin.pinnedById && pin.pinnedById.toLowerCase() === String(viewerId).toLowerCase();
  return `Pinned by ${mine ? 'you' : (pin.pinnedBy || 'someone')}`;
}

// Header button label, count included only when there is one.
export function pinButtonLabel(count) {
  return count > 0 ? `Pinned messages, ${count}` : 'Pinned messages';
}

export const badgeText = (count) => (count > 99 ? '99+' : String(count));

// System line text built client-side from the sender (never trust frame text).
export function systemLineText(msg) {
  return `${msg.mine ? 'You' : (msg.sender || 'Someone')} pinned a message`;
}

// Apply an unpin/pin to a list locally (optimistic helpers).
export const withoutPin = (list, messageId) => list.filter((p) => p.messageId !== messageId);

function listUrl(userId, contact, limit, offset) {
  const u = encodeURIComponent(userId);
  const qs = `?limit=${limit}&offset=${offset}`;
  return contact.type === 'friend'
    ? `${API}/message-pins/${u}/dm/${encodeURIComponent(contact.id)}${qs}`
    : `${API}/message-pins/${u}/group/${encodeURIComponent(contact.group_id || contact.id)}${qs}`;
}

async function errorFor(res) {
  let code = null;
  try {
    const d = await res.json();
    if (d && d.detail && typeof d.detail === 'object') code = d.detail.code || null;
  } catch { /* keep null */ }
  if (res.status === 404) return new PinError('unavailable', PIN_GONE_COPY);
  if (res.status === 429) return new PinError('rate', PIN_RATE_COPY);
  if (res.status === 403 && code === 'terms_reaccept_required') {
    return new PinError('terms', 'Please review and accept the updated Terms to continue.');
  }
  return new PinError('failed', PIN_FALLBACK);
}

async function send(userId, messageId, method) {
  let res;
  try {
    res = await fetch(
      `${API}/message-pins/${encodeURIComponent(userId)}/${encodeURIComponent(messageId)}`,
      { method, credentials: 'include' },
    );
  } catch {
    throw new PinError('failed', 'Could not reach the server.');
  }
  if (!res.ok) throw await errorFor(res);
  let body = null;
  try { body = await res.json(); } catch { /* handled below */ }
  if (!body || typeof body.pinned !== 'boolean') throw new PinError('failed', PIN_FALLBACK);
  return body.pinned;
}

export const pinMessageRequest = (userId, messageId) => send(userId, messageId, 'POST');
export const unpinMessageRequest = (userId, messageId) => send(userId, messageId, 'DELETE');

export async function fetchPins(userId, contact, { limit = PIN_PAGE_LIMIT, offset = 0 } = {}) {
  let res;
  try {
    res = await fetch(listUrl(userId, contact, limit, offset), { credentials: 'include' });
  } catch {
    throw new PinError('failed', PIN_LIST_ERROR);
  }
  if (!res.ok) {
    const err = await errorFor(res);
    if (err.kind === 'failed') err.message = PIN_LIST_ERROR;
    throw err;
  }
  let body = null;
  try { body = await res.json(); } catch { /* handled below */ }
  const parsed = parsePinList(body);
  if (!parsed) throw new PinError('failed', PIN_LIST_ERROR);
  return parsed;
}
