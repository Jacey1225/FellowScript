// Task 20261002-shared-foundation step 8. Thin client for GET /app/capabilities
// (shared-contract-v2 sections 9.2 and 6.12). This is the one discovery
// mechanism for server-gated features and for the live "Updated Terms" check.
//
// Fails closed: any non-200, network error, timeout or malformed body resolves
// to CAPABILITIES_OFF (every feature false, no links, terms_current treated as
// true so a missing endpoint can never trap a user behind a terms gate). The
// function never throws and never fabricates an "on" value.
import { API } from '../config.js';

export const CAPABILITIES_TIMEOUT_MS = 5000;

export const CAPABILITIES_OFF = Object.freeze({
  features: Object.freeze({}),
  links: Object.freeze({ explore: null }),
  termsCurrent: true,
});

// Returns the normalised capabilities, or null when the body is malformed.
export function parseCapabilities(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return null;
  const { features, links, terms_current: termsCurrent } = body;
  if (!features || typeof features !== 'object' || Array.isArray(features)) return null;
  if (typeof termsCurrent !== 'boolean') return null;
  const out = {};
  Object.keys(features).forEach((k) => { out[k] = features[k] === true; });
  const explore = links && typeof links === 'object' && typeof links.explore === 'string' && out.explorer_browse
    ? links.explore : null;
  return { features: out, links: { explore }, termsCurrent };
}

export async function fetchCapabilities() {
  const ctrl = typeof AbortController !== 'undefined' ? new AbortController() : null;
  const timer = ctrl ? setTimeout(() => ctrl.abort(), CAPABILITIES_TIMEOUT_MS) : null;
  try {
    const res = await fetch(`${API}/app/capabilities`, {
      credentials: 'include',
      cache: 'no-store',
      signal: ctrl ? ctrl.signal : undefined,
    });
    if (res.status !== 200) return CAPABILITIES_OFF;
    return parseCapabilities(await res.json()) || CAPABILITIES_OFF;
  } catch {
    return CAPABILITIES_OFF;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

// POST /user/{user_id}/accept-terms. Throws on failure so the gate never
// pretends consent was recorded.
export async function acceptCurrentTerms(userId) {
  let res;
  try {
    res = await fetch(`${API}/user/${encodeURIComponent(userId)}/accept-terms`, {
      method: 'POST', credentials: 'include',
    });
  } catch {
    throw new Error('Could not reach the server.');
  }
  if (!res.ok) throw new Error("Couldn't save your agreement. Please try again.");
}
