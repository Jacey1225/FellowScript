import { useEffect, useRef } from 'react';
import { useLocation } from 'react-router-dom';
import { API } from '../config.js';
import { getOrCreateDeviceId } from '../lib/deviceId.js';
import { isDesktopApp } from '../lib/desktopScope.js';

// Client-side half of the Activity Monitoring visit-tracking beacon (task
// 20260918-admin-activity-monitoring). Fires a fire-and-forget
// `POST /activity-monitoring/visits` on every route change so the admin
// panel's "website visits" chart has real data to aggregate, per the intake
// spec's app-wide-instrumentation framing ("website visits" broadly, not
// just specific pages).
//
// Mounted once, inside <HashRouter> but outside <Routes> (see App.jsx), so
// it sees every navigation exactly once via useLocation() without being
// remounted per-route.
//
// Renders nothing -- this is a side-effect-only component, matching the
// no-UI-of-its-own framing in design-notes.md §7.
export default function VisitTracker() {
  const location = useLocation();
  const deviceIdRef = useRef(null);

  useEffect(() => {
    // Out of scope per the intake spec ("iOS or desktop instrumentation ...
    // no requirement mentions ... the Tauri desktop shell logging visits"):
    // the desktop app loads this same bundle (lib/desktopScope.js), so this
    // is the one place that distinction has to be made explicitly rather
    // than assumed away.
    if (isDesktopApp()) return;

    if (!deviceIdRef.current) deviceIdRef.current = getOrCreateDeviceId();

    // location.pathname (not .hash/.search) is the clean, query-string-free
    // path HashRouter resolves internally -- exactly the shape
    // VisitCreate.path requires server-side (no "?", no control characters;
    // see api/schemas/activity_monitoring.py).
    const path = location.pathname.slice(0, 200);

    fetch(`${API}/activity-monitoring/visits`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ device_id: deviceIdRef.current, path }),
      // Best-effort telemetry: must survive a page unload mid-navigation
      // (keepalive) but must never block or surface an error to the visitor
      // -- same fail-soft posture the backend route itself documents for a
      // dropped insert.
      keepalive: true,
    }).catch(() => {});
  }, [location.pathname]);

  return null;
}
