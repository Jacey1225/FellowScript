// Task 20261003-web-reader-ios-parity (step 1). Client-side session gating that
// mirrors iOS FSSession.isJoinWindowOpen / SessionDetailSheet.isHost. Both are
// cosmetic UX signals only: the server (api/backend/interactions/devotion.py
// is_join_window_open, DELETE /devotions/ host check) is the access boundary.
// Both fail closed: missing or malformed data means "not allowed".

// Same value as iOS FSSession.joinGraceMinutes and the recommended deploy value
// of the server's SESSION_JOIN_GRACE_MINUTES. No API exposes the server's
// value (checked: devotion payload, /app/capabilities), so this is the single
// web copy. Keep in sync with the backend config.
export const JOIN_GRACE_MINUTES = 10;

function parseTime(v) {
  if (typeof v !== 'string' || !v.trim()) return null;
  const t = Date.parse(v);
  return Number.isNaN(t) ? null : t;
}

// True when `now` is inside [time_start - grace, time_end]. A missing or
// malformed time_start is never open. A missing or malformed time_end leaves
// the window open-ended once the start has opened it (server contract 2.4).
export function isJoinWindowOpen(session, now = Date.now(), graceMinutes = JOIN_GRACE_MINUTES) {
  const start = parseTime(session?.time_start);
  if (start === null) return false;
  if (now < start - graceMinutes * 60 * 1000) return false;
  const end = parseTime(session?.time_end);
  if (end === null) return true;
  return now <= end;
}

// Edit/Delete are host-only. An empty creator_id or user_id fails closed.
export function isSessionHost(session, user) {
  const creator = session?.creator_id;
  const uid = user?.user_id;
  if (typeof creator !== 'string' || !creator) return false;
  if (typeof uid !== 'string' || !uid) return false;
  return creator === uid;
}
