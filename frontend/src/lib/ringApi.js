// Task 20261003-web-reader-ios-parity (step 2). Client for the existing
// POST /devotions/ring (api/routes/devotion.py ring_members). Mirrors iOS
// RingMembersSheet: one request, each target reported independently as
// { sent, reason }. Throws RingError on any non-2xx / network failure
// (throw-not-fabricate). Never logs ids, tokens or response bodies.
import { API } from '../config.js';

export class RingError extends Error {
  constructor(message, status) {
    super(message);
    this.name = 'RingError';
    this.status = status;
  }
}

export async function ringMembers(userId, sessionId, targetIds) {
  let res;
  try {
    res = await fetch(`${API}/devotions/ring`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ devotion_id: sessionId, user_id: userId, target_ids: targetIds }),
    });
  } catch {
    throw new RingError('Could not reach the server.', 0);
  }
  if (!res.ok) {
    // 404 = ring disabled server-side; 429 = coarse per-IP backstop.
    throw new RingError(
      res.status === 404 ? 'Ringing is not available right now.' : "Couldn't send",
      res.status,
    );
  }
  let body;
  try { body = await res.json(); } catch { throw new RingError("Couldn't send", res.status); }
  if (!body || typeof body !== 'object' || !body.results || typeof body.results !== 'object') {
    throw new RingError("Couldn't send", res.status);
  }
  return body.results;
}

// Maps one target's result onto a row state, following iOS apply(results:to:).
// A missing result never leaves a row stuck "sending".
export function rowStateFromResult(result) {
  if (!result || typeof result !== 'object') return { kind: 'error', caption: "Couldn't send" };
  if (result.sent === true) return { kind: 'sent' };
  switch (result.reason) {
    case 'rate_limited': return { kind: 'rateLimited' };
    case 'unreachable': return { kind: 'error', caption: 'Not reachable' };
    case 'no_voip_token': return { kind: 'error', caption: "Can't ring this device" };
    case 'send_failed': return { kind: 'error', caption: "Couldn't send" };
    case 'no_active_call': return { kind: 'error', caption: 'Call not started yet' };
    default: return { kind: 'error', caption: 'Unavailable' }; // invalid_target / not_a_member / nil
  }
}
