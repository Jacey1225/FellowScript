// Task 20261001-explorer-join-requests step 7: client for api/routes/join_requests.py
// (flag join_requests). Throws ExplorerApiError (status, code, retryAfter) on any
// non-2xx or network failure; nothing is fabricated. Per-user rate limits are
// server-side, the client only honours Retry-After. Applicant notes and
// usernames returned here are untrusted text: callers render them as plain text
// only, and applicant_user_id is used solely for Report and Block.
import { request } from './explorerApi.js';

const base = (userId) => `/join-requests/${encodeURIComponent(userId)}`;
const groupBase = (userId, groupId) => `${base(userId)}/groups/${encodeURIComponent(groupId)}`;
const json = (method, body) => ({
  method,
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
});

export const NOTE_MAX = 280;
export const UNDO_FALLBACK_MS = 10000;

// The feature is on only when the capabilities answer says so (fail closed).
export function joinRequestsEnabled(features) {
  return features?.join_requests === true;
}

export function requestToJoin(userId, publicId, note) {
  const text = typeof note === 'string' ? note.trim() : '';
  return request(
    `${base(userId)}/listings/${encodeURIComponent(publicId)}/request`,
    json('POST', text ? { note: text } : {}),
    "Couldn't send your request. Please try again.",
  );
}

// { requests: [{id,status,created_at,public_id,title,group_id?}], already_member? }
export function fetchMyRequests(userId, publicId) {
  const qs = publicId ? `?public_id=${encodeURIComponent(publicId)}` : '';
  return request(`${base(userId)}/requests${qs}`, undefined, "Couldn't load your requests.");
}

export function withdrawRequest(userId, requestId) {
  return request(`${base(userId)}/requests/${encodeURIComponent(requestId)}/withdraw`, { method: 'POST' }, "Couldn't withdraw your request.");
}

// { accepting_requests, pending_count, requests: [{id, applicant_user_id, username, profile_photo_url, note, created_at}] }
export function fetchGroupRequests(userId, groupId) {
  return request(`${groupBase(userId, groupId)}/requests`, undefined, "Couldn't load join requests.");
}

export function approveRequest(userId, groupId, requestId) {
  return request(`${groupBase(userId, groupId)}/requests/${encodeURIComponent(requestId)}/approve`, { method: 'POST' }, "Couldn't approve this request.");
}

export function denyRequest(userId, groupId, requestId, blockReapply = false) {
  return request(
    `${groupBase(userId, groupId)}/requests/${encodeURIComponent(requestId)}/deny`,
    json('POST', { block_reapply: !!blockReapply }),
    "Couldn't deny this request.",
  );
}

export function undoDenyRequest(userId, groupId, requestId) {
  return request(`${groupBase(userId, groupId)}/requests/${encodeURIComponent(requestId)}/undo-deny`, { method: 'POST' }, "Couldn't undo.");
}

export function setAccepting(userId, groupId, accepting) {
  return request(`${groupBase(userId, groupId)}/accepting`, json('PUT', { accepting: !!accepting }), "Couldn't update. Try again.");
}

// Report / Block use applicant_user_id and nothing else does.
export function reportApplicant(applicantUserId, reason = 'other', detail = '') {
  return request(
    '/reports/',
    json('POST', { content_type: 'user', reported_user_id: applicantUserId, reason, detail }),
    "Couldn't send your report. Please try again.",
  );
}

export function blockApplicant(userId, applicantUserId) {
  return request(
    `/blocks/${encodeURIComponent(userId)}/${encodeURIComponent(applicantUserId)}`,
    { method: 'POST' },
    "Couldn't block this person. Please try again.",
  );
}

export function dateLabel(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}
