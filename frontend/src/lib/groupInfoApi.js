// Task 20260929-group-info-panel: thin wrappers over the member-only group
// info endpoints (api/routes/group_info.py). Every function throws on any
// non-2xx or network failure (throw-not-fabricate): callers decide what to
// show, and never receive an invented default. A thrown error carries the
// HTTP `status` (0 for a network failure) and a user-presentable `message`.
import { API } from '../config.js';

export const GROUP_PHOTO_LIMITS = {
  maxBytes: 15 * 1024 * 1024,
  accept: ['image/jpeg', 'image/png', 'image/webp', 'image/heic'],
  oversizeCopy: 'Photos can be up to 15MB.',
};

export class GroupInfoError extends Error {
  constructor(message, status) {
    super(message);
    this.name = 'GroupInfoError';
    this.status = status;
  }
}

async function request(path, options, fallback) {
  let res;
  try {
    res = await fetch(`${API}${path}`, options);
  } catch (err) {
    throw new GroupInfoError('Could not reach the server.', 0);
  }
  if (!res.ok) {
    let detail = fallback;
    try {
      const d = await res.json();
      if (typeof d.detail === 'string') detail = d.detail;
    } catch (err) {
      // Non-JSON error body: keep the fallback copy.
    }
    throw new GroupInfoError(detail, res.status);
  }
  if (res.status === 204) return {};
  return res.json();
}

const json = (method, body) => ({
  method,
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
});

const base = (userId, groupId) => `/groups/${userId}/${groupId}`;

export function fetchGroupInfo(userId, groupId) {
  return request(`${base(userId, groupId)}/info`, undefined, "Couldn't refresh just now.");
}

export function renameGroup(userId, groupId, title) {
  return request(`${base(userId, groupId)}/title`, json('PUT', { title }), "That name didn't save. Please try again.");
}

// Owner only. `maxMembers` null clears the cap. 403 = not the owner, 422 =
// out of range or below the current member count (message is user-presentable).
export function setGroupMaxMembers(userId, groupId, maxMembers) {
  return request(`${base(userId, groupId)}/max-members`, json('PUT', { max_members: maxMembers }), "Couldn't save the limit. Please try again.");
}

export function setGroupMuted(userId, groupId, muted) {
  return request(`${base(userId, groupId)}/mute`, { method: muted ? 'PUT' : 'DELETE' }, "Couldn't update notifications. Please try again.");
}

export function removeGroupPhoto(userId, groupId) {
  return request(`${base(userId, groupId)}/photo`, { method: 'DELETE' }, "Couldn't remove the photo. Please try again.");
}

export function confirmGroupPhoto(userId, groupId, objectKey) {
  return request(`${base(userId, groupId)}/photo/confirm`, json('POST', { object_key: objectKey }), "Couldn't save the photo. Please try again.");
}

// Presigned-POST flow (server never receives the bytes): request policy,
// upload straight to S3, then confirm. Resolves to the confirm response
// ({ photo_url }).
export async function uploadGroupPhoto(userId, groupId, file) {
  if (file.size > GROUP_PHOTO_LIMITS.maxBytes) throw new GroupInfoError(GROUP_PHOTO_LIMITS.oversizeCopy, 0);
  if (!GROUP_PHOTO_LIMITS.accept.includes(file.type)) {
    throw new GroupInfoError('Choose a JPG, PNG, or WebP under 15MB.', 0);
  }
  const { url, fields, object_key: objectKey } = await request(
    `${base(userId, groupId)}/photo/upload-url`,
    json('POST', { content_type: file.type, size_bytes: file.size }),
    "That file type isn't supported here.",
  );
  const form = new FormData();
  Object.entries(fields || {}).forEach(([k, v]) => form.append(k, v));
  form.append('file', file);
  let up;
  try {
    up = await fetch(url, { method: 'POST', body: form });
  } catch (err) {
    throw new GroupInfoError('Upload failed. Please try again.', 0);
  }
  if (!up.ok && up.status !== 204) throw new GroupInfoError('Upload failed. Please try again.', up.status);
  return confirmGroupPhoto(userId, groupId, objectKey);
}

// One gallery page. `cursor` is the { timestamp, id } pair from the previous
// page's next_cursor_*, or null for the first page. `kind` null = all kinds.
export function fetchGroupGallery(userId, groupId, { kind = null, cursor = null } = {}) {
  const qs = new URLSearchParams();
  if (kind) qs.set('kind', kind);
  if (cursor) {
    qs.set('cursor_timestamp', cursor.timestamp);
    qs.set('cursor_id', cursor.id);
  }
  const q = qs.toString();
  return request(`${base(userId, groupId)}/gallery${q ? `?${q}` : ''}`, undefined, "Couldn't load shared items.");
}
