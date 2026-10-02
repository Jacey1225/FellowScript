// Task 20261001-explorer-listings step 10: client for the owner (signed-in)
// publish routes in api/routes/explorer.py: /explorer/{user_id}/options,
// /groups, /groups/{group_id}/listing (GET, PUT, DELETE), /listing/submit and
// /listing/unpublish. Throws ExplorerApiError (status, code, retryAfter) on any
// non-2xx or network failure; nothing is fabricated. A 404 means the flag is
// off for this user or the group is not theirs (uniform on purpose).
import { request } from './explorerApi.js';

const base = (userId) => `/explorer/${encodeURIComponent(userId)}`;
const listingPath = (userId, groupId) => `${base(userId)}/groups/${encodeURIComponent(groupId)}/listing`;
const json = (method, body) => ({
  method,
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
});

export function fetchOwnerOptions(userId) {
  return request(`${base(userId)}/options`, undefined, "Couldn't load the form.");
}

export function fetchOwnerGroups(userId) {
  return request(`${base(userId)}/groups`, undefined, "Couldn't load your groups.");
}

export function fetchOwnerListing(userId, groupId) {
  return request(listingPath(userId, groupId), undefined, "Couldn't load this listing.");
}

export function saveOwnerListing(userId, groupId, body) {
  return request(listingPath(userId, groupId), json('PUT', body), "Couldn't save your listing. Please try again.");
}

export function submitOwnerListing(userId, groupId, body) {
  return request(`${listingPath(userId, groupId)}/submit`, json('POST', body), "Couldn't submit your listing. Please try again.");
}

export function unpublishOwnerListing(userId, groupId) {
  return request(`${listingPath(userId, groupId)}/unpublish`, { method: 'POST' }, "Couldn't unpublish. Please try again.");
}

export function deleteOwnerListing(userId, groupId) {
  return request(listingPath(userId, groupId), { method: 'DELETE' }, "Couldn't delete the listing. Please try again.");
}
