// Task 20261030-user-profiles: thin wrappers over api/routes/profile.py plus
// the existing unfriend/block/report endpoints. Every function throws a
// ProfileApiError on any non-2xx or network failure (throw-not-fabricate);
// `status` is 0 for a network failure. Callers decide what a 404 means.
import { API } from '../config.js';

export const BIO_MAX_LENGTH = 160;

export class ProfileApiError extends Error {
  constructor(message, status) {
    super(message);
    this.name = 'ProfileApiError';
    this.status = status;
  }
}

async function request(path, options, fallback) {
  let res;
  try {
    res = await fetch(`${API}${path}`, options);
  } catch {
    throw new ProfileApiError('Could not reach the server.', 0);
  }
  if (!res.ok) {
    let message = fallback;
    try {
      const d = await res.json();
      if (typeof d?.detail === 'string' && d.detail) message = d.detail;
    } catch {
      // Non-JSON error body: keep the fallback copy.
    }
    throw new ProfileApiError(message, res.status);
  }
  if (res.status === 204) return {};
  return res.json();
}

const enc = encodeURIComponent;
const jsonBody = (method, body) => ({
  method,
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
});

export const fetchProfile = (targetId) =>
  request(`/profiles/${enc(targetId)}`, undefined, "Couldn't load this profile.");

export const saveBio = (userId, bio) =>
  request(`/profile/${enc(userId)}/bio`, jsonBody('PUT', { bio }), "Couldn't save your bio. Your text is still here.");

export const sendFriendRequest = (targetId) =>
  request(`/profiles/${enc(targetId)}/friend-request`, { method: 'POST' }, "Couldn't send that right now. Please try again.");

export const acceptFriendRequest = (targetId) =>
  request(`/profiles/${enc(targetId)}/friend-accept`, { method: 'POST' }, "Couldn't accept that right now. Please try again.");

export const DECLINE_FAILURE = "Couldn't decline that right now. Please try again.";

// Task 20261030-profile-everywhere: recipient declines an incoming request.
// The server answers 204 whether or not a request existed (no probing).
export const declineFriendRequest = (userId, senderId) =>
  request(`/friends/${enc(userId)}/requests/${enc(senderId)}/decline`, { method: 'POST' }, DECLINE_FAILURE);

export const unfriend = (userId, friendId) =>
  request(`/friends/${enc(userId)}/${enc(friendId)}`, { method: 'DELETE' }, "Couldn't remove that friend. Please try again.");

export const blockProfile = (userId, targetId) =>
  request(`/blocks/${enc(userId)}/${enc(targetId)}`, { method: 'POST' }, "Couldn't block that user. Please try again.");

export const unblockProfile = (userId, targetId) =>
  request(`/blocks/${enc(userId)}/${enc(targetId)}`, { method: 'DELETE' }, "Couldn't unblock that user. Please try again.");

export const reportProfile = (targetId, reason, detail = '') =>
  request('/reports/', jsonBody('POST', { content_type: 'user', reported_user_id: targetId, reason, detail }),
    'Could not submit your report. Please try again.');
