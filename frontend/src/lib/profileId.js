// Task 20261030-profile-everywhere: deny-by-default profile target check.
// Only a well-formed user id (UUID) is ever a profile target, so display-name
// fallbacks (e.g. uid.slice(0, 4)) and legacy placeholders never navigate.
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isProfileId(id) {
  return typeof id === 'string' && UUID_RE.test(id);
}

export function profilePath(id) {
  return isProfileId(id) ? `/profile/${encodeURIComponent(id)}` : null;
}
