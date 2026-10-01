// Task 20260929-group-invite-links: thin wrappers over api/routes/invites.py.
// Every function throws on any non-2xx or network failure (throw-not-
// fabricate). A thrown InviteApiError carries the HTTP `status` (0 for a
// network failure), the backend's machine `code` (not_found | expired |
// revoked | full | blocked | link_limit | forbidden ...) when it sent one,
// and a user-presentable `message`. The plaintext token is only ever sent in
// a POST body (preview/redeem) and is never logged here.
import { API } from '../config.js';

export class InviteApiError extends Error {
  constructor(message, status, code = null) {
    super(message);
    this.name = 'InviteApiError';
    this.status = status;
    this.code = code;
  }
}

// Tokens are secrets.token_urlsafe(32): exactly 43 url-safe base64 chars.
const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;
export function isWellFormedInviteToken(token) {
  return typeof token === 'string' && TOKEN_RE.test(token);
}

// The only host an invite URL may name when pasted into the desktop app.
export const INVITE_HOST = 'fellowscript.com';

// Accepts a full invite URL (https://fellowscript.com/join/<token>, with an
// optional #/join/<token> web form) or a bare token. Returns the validated
// token, or null when the input is not a FellowScript invite link.
export function parseInviteInput(input) {
  const raw = (input || '').trim();
  if (!raw) return null;
  if (isWellFormedInviteToken(raw)) return raw;
  let url;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:' || (url.hostname !== INVITE_HOST && url.hostname !== `www.${INVITE_HOST}`)) return null;
  const path = url.pathname.match(/^\/join\/([^/]+)\/?$/);
  if (path && isWellFormedInviteToken(path[1])) return path[1];
  const hash = url.hash.match(/^#\/join\/([^/]+)\/?$/);
  if (hash && isWellFormedInviteToken(hash[1])) return hash[1];
  return null;
}

async function request(path, options, fallback) {
  let res;
  try {
    res = await fetch(`${API}${path}`, options);
  } catch {
    throw new InviteApiError('Could not reach the server.', 0);
  }
  if (!res.ok) {
    let message = fallback;
    let code = null;
    try {
      const d = await res.json();
      const detail = d?.detail;
      if (detail && typeof detail === 'object') {
        if (typeof detail.code === 'string') code = detail.code;
        if (typeof detail.message === 'string') message = detail.message;
      } else if (typeof detail === 'string') {
        message = detail;
      }
    } catch {
      // Non-JSON error body: keep the fallback copy.
    }
    throw new InviteApiError(message, res.status, code);
  }
  if (res.status === 204) return {};
  return res.json();
}

const json = (method, body) => ({
  method,
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
});

// Public. Resolves { kind, group_name, photo_url, inviter_username,
// member_count }. Any unusable token is a uniform 404 (code not_found).
export function previewInvite(token) {
  return request('/invites/preview', json('POST', { token }), "This invite link isn't valid anymore.");
}

// Authenticated. Resolves { kind, target_id, joined, already_member }.
export function redeemInvite(userId, token) {
  return request(`/invites/${userId}/redeem`, json('POST', { token }), "Couldn't join the group. Please try again.");
}

// Resolves { invites: [...], options: {...} }. 404 = feature unavailable.
export function listGroupInvites(userId, groupId) {
  return request(`/invites/${userId}/groups/${groupId}`, undefined, "Couldn't load invite links.");
}

// Resolves { invite_id, token, url, created_at, expires_at, max_uses, use_count }.
export function createGroupInvite(userId, groupId, { expiresInDays, maxUses }) {
  return request(
    `/invites/${userId}/groups/${groupId}`,
    json('POST', { expires_in_days: expiresInDays, max_uses: maxUses }),
    "Couldn't create the link. Please try again.",
  );
}

export function revokeInvite(userId, inviteId) {
  return request(`/invites/${userId}/${inviteId}`, { method: 'DELETE' }, "Couldn't revoke. Please try again.");
}

// Resolves { revoked: n }.
export function resetGroupInvites(userId, groupId) {
  return request(`/invites/${userId}/groups/${groupId}/reset`, { method: 'POST' }, "Couldn't reset the links. Please try again.");
}

// Task 20260930-subscription-seat-invites: plan-owner-only sibling routes.
// Opening a subscription link files a join *request*; it never grants access.
// 403 = not the plan owner; 409 not_eligible = plan can't take links.
export function listSubscriptionInvites(userId, subscriptionId) {
  return request(`/invites/${userId}/subscriptions/${subscriptionId}`, undefined, "Couldn't load invite links.");
}

export function createSubscriptionInvite(userId, subscriptionId, { expiresInDays, maxUses }) {
  return request(
    `/invites/${userId}/subscriptions/${subscriptionId}`,
    json('POST', { expires_in_days: expiresInDays, max_uses: maxUses }),
    "Couldn't create the link. Please try again.",
  );
}

// Resolves { revoked: n }.
export function resetSubscriptionInvites(userId, subscriptionId) {
  return request(`/invites/${userId}/subscriptions/${subscriptionId}/reset`, { method: 'POST' }, "Couldn't reset the links. Please try again.");
}
