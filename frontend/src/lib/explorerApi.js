// Task 20261001-explorer-listings step 9: thin client for the public Explorer
// browse API (api/routes/explorer.py). Frozen routes: GET /explorer/config,
// /explorer/filters, /explorer/listings, /explorer/listings/{public_id}.
// Every function except probeExploreConfig throws ExplorerApiError on a
// non-2xx or network failure (throw-not-fabricate). The probe never throws: it
// fails closed, so any status but 200, any network error and any body that is
// not exactly {browse: true} means "hidden". Responses carry no PII; nothing
// here logs listing text or filter values.
import { API } from '../config.js';

export class ExplorerApiError extends Error {
  constructor(message, status, code = null, retryAfter = null) {
    super(message);
    this.name = 'ExplorerApiError';
    this.status = status; // 0 = network failure
    this.code = code;
    this.retryAfter = retryAfter; // seconds, from Retry-After on a 429
  }
}

export const PROBE_TIMEOUT_MS = 5000;
const MAX_RETRY_AFTER_S = 120;

export function parseRetryAfter(value) {
  const n = Number.parseInt(value, 10);
  if (!Number.isFinite(n) || n < 0) return null;
  return Math.min(n, MAX_RETRY_AFTER_S);
}

// Signed-out probe. True only for HTTP 200 with body.browse === true.
export async function probeExploreConfig() {
  const ctrl = typeof AbortController !== 'undefined' ? new AbortController() : null;
  const timer = ctrl ? setTimeout(() => ctrl.abort(), PROBE_TIMEOUT_MS) : null;
  try {
    const res = await fetch(`${API}/explorer/config`, { signal: ctrl ? ctrl.signal : undefined });
    if (res.status !== 200) return false;
    const body = await res.json();
    return !!body && typeof body === 'object' && body.browse === true;
  } catch {
    return false;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

export async function request(path, options, fallback) {
  let res;
  try {
    res = await fetch(`${API}${path}`, options);
  } catch {
    throw new ExplorerApiError('Could not reach the server.', 0);
  }
  if (!res.ok) {
    let message = fallback;
    let code = null;
    try {
      const d = await res.json();
      const detail = d?.detail;
      if (detail && typeof detail === 'object' && !Array.isArray(detail)) {
        if (typeof detail.code === 'string') code = detail.code;
        if (typeof detail.message === 'string') message = detail.message;
      } else if (typeof detail === 'string') {
        message = detail;
      }
    } catch {
      // Non-JSON error body: keep the fallback copy.
    }
    const retryAfter = res.status === 429 ? parseRetryAfter(res.headers?.get?.('Retry-After')) : null;
    throw new ExplorerApiError(message, res.status, code, retryAfter);
  }
  if (res.status === 204) return {};
  return res.json();
}

// Resolves { vocab: {key: [{slug,label}]}, countries, size_buckets, limits, support_email }.
export function fetchFilters() {
  return request('/explorer/filters', undefined, "Couldn't load the filters.");
}

// Array filters repeat the parameter; empty values are dropped.
export function buildListingsQuery(filters = {}, { q, cursor, includeFull, limit } = {}) {
  const sp = new URLSearchParams();
  Object.entries(filters).forEach(([key, value]) => {
    if (Array.isArray(value)) value.forEach((v) => { if (v) sp.append(key, v); });
    else if (typeof value === 'string' && value.trim()) sp.set(key, value.trim());
  });
  if (q && q.trim()) sp.set('q', q.trim());
  if (includeFull) sp.set('include_full', 'true');
  if (limit) sp.set('limit', String(limit));
  if (cursor && cursor.timestamp && cursor.id) {
    sp.set('cursor_timestamp', cursor.timestamp);
    sp.set('cursor_id', cursor.id);
  }
  return sp.toString();
}

// Resolves { listings: [...], page: { limit, has_more, next_cursor_timestamp, next_cursor_id } }.
export function fetchListings(filters, opts) {
  const qs = buildListingsQuery(filters, opts);
  return request(`/explorer/listings${qs ? `?${qs}` : ''}`, undefined, "Couldn't load groups.");
}

// Resolves the card fields plus { description_blocks, requestable }.
export function fetchListing(publicId) {
  return request(`/explorer/listings/${encodeURIComponent(publicId)}`, undefined, "Couldn't load this group.");
}

export const REPORT_REASONS = [
  { value: 'inappropriate', label: 'Inappropriate content' },
  { value: 'misleading', label: 'Misleading or false' },
  { value: 'spam', label: 'Spam or advertising' },
  { value: 'not_adults_only', label: 'Not for adults 18 and over' },
  { value: 'other', label: 'Something else' },
];

// Signed in only (session cookie). Sends the public_id, never an internal id.
export function reportListing(publicId, reason, detail = '') {
  return request(
    '/reports/',
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content_type: 'group_listing', content_id: publicId, reason, detail }),
    },
    "Couldn't send your report. Please try again.",
  );
}

// Position of a card/detail id in a path. Public ids are 10 url-safe chars.
export const PUBLIC_ID_RE = /^[A-Za-z0-9_-]{6,32}$/;
export function isWellFormedPublicId(id) {
  return typeof id === 'string' && PUBLIC_ID_RE.test(id);
}
