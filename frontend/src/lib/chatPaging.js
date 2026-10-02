// Task 20261001-chat-pagination step 7. Pure helpers for cursor-paginated chat
// history (shared-contract-v2 sections 6.10, 6.11): response-shape detection,
// cursor query encoding, id-based merge/dedup and ack reconciliation. No React,
// no network, so every rule here is unit-testable on its own.
//
// Rules the callers rely on:
//  - A response with no `page` block (or a non-array `messages`) is the legacy
//    full-history shape; parsePage returns null and the caller falls back.
//  - Merges are by message id. Fetched pages are never re-sorted by timestamp
//    string (legacy rows carry `str(timestamp)`, paged rows ISO-Z, and the
//    server orders ties by seq); order is whatever the server returned.
//  - A pending (not yet acked) bubble has no id and is never removed by a
//    merge; only an ack, or the lost-ack fallback, resolves it.

export const INITIAL_PAGE_LIMIT = 30;
export const OLDER_PAGE_LIMIT = 30;
export const ACK_FALLBACK_MS = 5000;
export const ACK_MATCH_WINDOW_MS = 120000;

const CLIENT_REF_RE = /^[A-Za-z0-9_-]{1,64}$/;

export function newClientRef() {
  let ref = '';
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    ref = crypto.randomUUID();
  } else {
    ref = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 12)}`;
  }
  return CLIENT_REF_RE.test(ref) ? ref : `c-${Date.now().toString(36)}`;
}

// One history row (legacy or paged) -> the message shape ChatThread renders.
// `mine` overrides the row's own flag (legacy rows are split into
// host_msgs/other_msgs instead of carrying one). `attachment_key` is never read.
export function toMessage(row, mine) {
  const isMine = mine === undefined ? !!row.mine : !!mine;
  const id = typeof row.id === 'string' && row.id ? row.id : null;
  const msg = {
    text: row.text,
    mine: isMine,
    timestamp: row.timestamp,
    sender: isMine ? '' : (row.from_user || ''),
    attachmentKind: row.attachment_kind || null,
    attachmentMeta: row.attachment_meta || null,
    attachmentUrl: row.attachment_url || null,
  };
  if (id) { msg.id = id; msg.key = id; }
  return msg;
}

// Paged response -> { messages, hasMore, cursor } or null when the body has no
// page block (legacy / old server).
export function parsePage(data) {
  if (!data || typeof data !== 'object') return null;
  const page = data.page;
  if (!page || typeof page !== 'object' || !Array.isArray(data.messages)) return null;
  const hasMore = page.has_more === true;
  const cursor = hasMore && typeof page.next_cursor_timestamp === 'string' && typeof page.next_cursor_id === 'string'
    ? {
        timestamp: page.next_cursor_timestamp,
        seq: Number.isInteger(page.next_cursor_seq) ? page.next_cursor_seq : null,
        id: page.next_cursor_id,
      }
    : null;
  return {
    messages: data.messages.map(r => toMessage(r)),
    // has_more without a usable cursor cannot be continued; treat as the end.
    hasMore: hasMore && cursor !== null,
    cursor,
  };
}

// Query string for the older-messages routes. URLSearchParams encodes the
// microsecond timestamp (the '+' of an offset must not become a space).
export function pageQuery(limit, cursor) {
  const qs = new URLSearchParams();
  qs.set('limit', String(limit));
  if (cursor) {
    qs.set('cursor_timestamp', cursor.timestamp);
    if (cursor.seq !== null && cursor.seq !== undefined) qs.set('cursor_seq', String(cursor.seq));
    qs.set('cursor_id', cursor.id);
  }
  return qs.toString();
}

// Prepend an older page, skipping rows whose id is already present.
export function mergeOlder(current, older) {
  const have = new Set(current.map(m => m.id).filter(Boolean));
  const fresh = older.filter(m => !m.id || !have.has(m.id));
  return fresh.length ? [...fresh, ...current] : current;
}

// Append a live frame unless a message with its id is already present.
export function mergeLive(current, msg) {
  if (msg.id && current.some(m => m.id === msg.id)) return current;
  return [...current, msg];
}

// Ack: replace the optimistic bubble in place (never append). If a row with
// the acked id already exists (a refetch beat the ack), delete the optimistic
// bubble instead. Unknown client_ref: no change.
export function reconcileAck(current, ack) {
  const idx = current.findIndex(m => m.clientRef && m.clientRef === ack.client_ref);
  if (idx === -1) return current;
  const dupe = current.some((m, i) => i !== idx && m.id === ack.id);
  if (dupe) return current.filter((_, i) => i !== idx);
  const next = current.slice();
  next[idx] = {
    ...current[idx],
    id: ack.id,
    timestamp: ack.timestamp || current[idx].timestamp,
    pending: false,
  };
  return next;
}

// Lost-ack fallback: among freshly fetched rows, the one that is mine, not
// already in the list, and matches the pending bubble's text + attachment kind
// within the match window. Closest in time wins. null when none.
export function findLostAckMatch(current, pendingMsg, fetched) {
  const have = new Set(current.map(m => m.id).filter(Boolean));
  const t0 = Date.parse(pendingMsg.timestamp);
  let best = null;
  let bestDelta = Infinity;
  for (const row of fetched) {
    if (!row.mine || !row.id || have.has(row.id)) continue;
    if ((row.text || '') !== (pendingMsg.text || '')) continue;
    if ((row.attachmentKind || null) !== (pendingMsg.attachmentKind || null)) continue;
    const delta = Math.abs(Date.parse(row.timestamp) - t0);
    if (!(delta <= ACK_MATCH_WINDOW_MS)) continue;
    if (delta < bestDelta) { best = row; bestDelta = delta; }
  }
  return best;
}
