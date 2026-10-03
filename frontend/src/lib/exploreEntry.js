// Task 20261003-web-reader-ios-parity (E1). The Explore groups entry in the
// Reader's Groups list. Visible only when the server reports explorer_browse
// for this user AND hands back an https Explore link (fail closed otherwise).
// Opened with window.open so the desktop shell hands it to the system browser
// (no new in-app route; desktopScope allowlist untouched).
export function exploreEntryUrl(caps) {
  if (!caps || !caps.features || caps.features.explorer_browse !== true) return null;
  const url = caps.links && caps.links.explore;
  if (typeof url !== 'string') return null;
  try {
    return new URL(url).protocol === 'https:' ? url : null;
  } catch {
    return null;
  }
}
