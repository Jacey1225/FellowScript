// Client-generated, client-persisted device identifier for the Activity
// Monitoring visit-tracking beacon (task 20260918-admin-activity-monitoring).
//
// Per security step 1's device-identifier decision: a random UUIDv4, created
// once and stored in localStorage (not a cookie -- avoids ambient inclusion
// on every request; see api/schemas/activity_monitoring.py's own docstring
// for the server-side half of this contract). Opaque to the server -- never
// derived from IP/User-Agent, never joined against `users`/`sessions`.
const STORAGE_KEY = 'fs_device_id';

// Same UUIDv4 shape the server's VisitCreate.device_id validator requires
// (api/schemas/activity_monitoring.py::_UUID_V4_RE) -- checked here too so a
// corrupted/hand-edited localStorage value gets replaced rather than sent
// as-is and rejected with a 422 on every subsequent beacon.
const UUID_V4_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function getOrCreateDeviceId() {
  try {
    const existing = localStorage.getItem(STORAGE_KEY);
    if (existing && UUID_V4_RE.test(existing)) return existing;

    // crypto.randomUUID() is already relied on elsewhere in this codebase
    // (useMessaging.js's group id) with no polyfill -- same assumption here.
    const fresh = crypto.randomUUID();
    localStorage.setItem(STORAGE_KEY, fresh);
    return fresh;
  } catch {
    // Storage unavailable (private-browsing lockdown, quota, etc.) -- fall
    // back to an in-memory-only id for this page load rather than throwing;
    // this is best-effort telemetry, not a feature the app depends on.
    return crypto.randomUUID();
  }
}
