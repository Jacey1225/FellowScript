// Task 20260929-group-announcements: thin wrappers over the member-only group
// announcement endpoints (api/routes/group_announcements.py). Same contract as
// groupInfoApi.js: every function throws on any non-2xx or network failure
// (throw-not-fabricate). A thrown error carries `status` (0 for network),
// a user-presentable `message`, and, for the free-limit 403, `gate` (the
// server's limits dict, e.g. { resource, allowed, used, limit }).
import { API } from '../config.js';

// Mirrors the server's ANNOUNCEMENTS_ENABLED flag. The server answers 404 for
// every route when it is off, which callers treat as "unavailable".
export const ANNOUNCEMENTS_ENABLED = true;

export const ANNOUNCEMENT_LIMITS = {
  titleMax: 255,
  descriptionMax: 5000,
  bannerMaxBytes: 15 * 1024 * 1024,
  bannerAccept: ['image/jpeg', 'image/png', 'image/webp', 'image/heic'],
  bannerHelper: 'JPG, PNG, or WebP, up to 15MB.',
  scheduleHorizonDays: 365,
};

export class AnnouncementsError extends Error {
  constructor(message, status, gate = null) {
    super(message);
    this.name = 'AnnouncementsError';
    this.status = status;
    this.gate = gate;
  }
}

async function request(path, options, fallback) {
  let res;
  try {
    res = await fetch(`${API}${path}`, options);
  } catch (err) {
    throw new AnnouncementsError('Could not reach the server.', 0);
  }
  if (!res.ok) {
    let detail = fallback;
    let gate = null;
    try {
      const d = await res.json();
      if (typeof d.detail === 'string') detail = d.detail;
      else if (d.detail && typeof d.detail === 'object' && 'allowed' in d.detail) gate = d.detail;
    } catch (err) {
      // Non-JSON error body: keep the fallback copy.
    }
    throw new AnnouncementsError(detail, res.status, gate);
  }
  if (res.status === 204) return {};
  return res.json();
}

const json = (method, body) => ({
  method,
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
});

const base = (userId, groupId) => `/groups/${userId}/${groupId}/announcements`;

// -> { announcements: [...], truncated, gate }
export function fetchAnnouncements(userId, groupId) {
  return request(base(userId, groupId), undefined, "Couldn't load announcements.");
}

// body: { title, description, banner_key?, publish_at? }
export function createAnnouncement(userId, groupId, body) {
  return request(base(userId, groupId), json('POST', body), "That didn't save. Please try again.");
}

// body carries only the changed fields (banner_key: null clears the banner).
export function updateAnnouncement(userId, groupId, announcementId, body) {
  return request(`${base(userId, groupId)}/${announcementId}`, json('PUT', body), "That didn't save. Please try again.");
}

export function deleteAnnouncement(userId, groupId, announcementId) {
  return request(`${base(userId, groupId)}/${announcementId}`, { method: 'DELETE' },
    "That announcement couldn't be deleted. Please try again.");
}

// Presigned-POST flow (server never receives the bytes). Resolves to the
// object key to send as `banner_key` on create/update.
export async function uploadAnnouncementBanner(userId, groupId, file) {
  if (file.size > ANNOUNCEMENT_LIMITS.bannerMaxBytes || !ANNOUNCEMENT_LIMITS.bannerAccept.includes(file.type)) {
    throw new AnnouncementsError(`Choose a JPG, PNG, or WebP under ${ANNOUNCEMENT_LIMITS.bannerMaxBytes / 1024 / 1024}MB.`, 0);
  }
  const { url, fields, object_key: objectKey } = await request(
    `${base(userId, groupId)}/banner/upload-url`,
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
    throw new AnnouncementsError('Upload failed. Please try again.', 0);
  }
  if (!up.ok && up.status !== 204) throw new AnnouncementsError('Upload failed. Please try again.', up.status);
  return objectKey;
}
