import React from 'react';
import { useLocation, Navigate } from 'react-router-dom';
import { isDesktopApp, isAllowedDesktopRoute, DESKTOP_FALLBACK_ROUTE } from '../lib/desktopScope.js';

// Defense against in-SPA navigation escaping the desktop app's restricted
// route surface (task 20260906-desktop-scope-lockdown). HashRouter Link
// clicks and navigate() calls are same-document history pushes that never
// produce a real webview navigation event, so Tauri's on_new_window hook
// (which only handles the external-link-to-system-browser handoff) can't
// see or intercept them -- this synchronous, render-time check is what
// actually enforces the allowlist for in-app navigation. A Tauri-side
// `on_navigation` check (desktop/src-tauri) is the separate defense-in-depth
// layer for real webview navigations (full reloads, `window.location`
// assignment) this component can't see either.
//
// Wraps <Routes> (see App.jsx) rather than each Route's element
// individually, so lib/desktopScope.js's DESKTOP_ALLOWED_ROUTES stays the
// one place restricting every route at once, and redirects at render time
// (via <Navigate>, not a post-mount effect) so a disallowed route's element
// never mounts even briefly.
//
// No-op entirely in the ordinary web browser: isDesktopApp() only reports
// true inside the Tauri webview, so the web frontend's full route set is
// completely unaffected.
export default function DesktopRouteGuard({ children }) {
  const location = useLocation();

  if (isDesktopApp() && !isAllowedDesktopRoute(location.pathname)) {
    return <Navigate to={DESKTOP_FALLBACK_ROUTE} replace />;
  }

  return children;
}
