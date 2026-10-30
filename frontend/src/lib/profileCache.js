// Task 20261030-user-profiles: in-memory profile cache (module scope, so it
// never touches disk and is gone on reload). Keyed by viewer + target so one
// account's cached bios can never be shown to another; cleared on sign-out.
const cache = new Map();
const key = (viewerId, targetId) => `${viewerId}:${targetId}`;

export const getCachedProfile = (viewerId, targetId) => cache.get(key(viewerId, targetId)) || null;
export const setCachedProfile = (viewerId, targetId, profile) => { cache.set(key(viewerId, targetId), profile); };
// A 404 (blocked/suspended/gone) or a local block/unfriend evicts; a network
// or 5xx failure must NOT call this (preserve-cache-on-failed-refresh).
export const evictCachedProfile = (viewerId, targetId) => { cache.delete(key(viewerId, targetId)); };
export const clearProfileCache = () => { cache.clear(); };
