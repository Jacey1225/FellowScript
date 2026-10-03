// Task 20261002-explorer-listing-media step 4. Listing images come from the
// server as short-lived presigned S3 GET URLs. The client still only uses a
// URL as the src of an <img> when it is https, has no credentials in it, and
// its host is first party: the S3 storage host (*.amazonaws.com) or this
// site's own API/site host. Anything else renders nothing. Never rendered as
// markup.
import { API } from '../config.js';

function hostOf(url) {
  try { return new URL(url).hostname.toLowerCase(); } catch { return ''; }
}

export function isFirstPartyMediaUrl(value) {
  if (typeof value !== 'string' || value.length > 4096) return false;
  let u;
  try { u = new URL(value.trim()); } catch { return false; }
  if (u.protocol !== 'https:' || u.username || u.password) return false;
  const host = u.hostname.toLowerCase();
  if (!host) return false;
  if (host.endsWith('.amazonaws.com')) return true;
  const own = hostOf(API);
  return !!own && host === own;
}

// Returns the url when it is safe to use as an <img src>, else null.
export function safeMediaUrl(value) {
  return isFirstPartyMediaUrl(value) ? value.trim() : null;
}
