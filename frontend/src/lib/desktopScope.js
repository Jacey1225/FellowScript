// Single source of truth for what the Tauri desktop shell is allowed to
// reach in-app (task 20260906-desktop-scope-lockdown). The desktop app
// loads the exact same HashRouter bundle as the web frontend
// (desktop/PROGRESS.md) rather than a separate build, so this allowlist is
// resolved at runtime -- a deliberate, documented exception to this repo's
// build-time-by-default configuration preference (see the security gate's
// step-1 result in .claude/pipeline/20260906-desktop-scope-lockdown/).
//
// Deny-by-default: only these routes are reachable via in-app navigation
// (Link clicks, navigate()) while running inside the desktop shell —
// everything else (Home, Privacy, Terms, the hidden /admin surface) is
// redirected to DESKTOP_FALLBACK_ROUTE by DesktopRouteGuard. Auth-flow
// routes are included as necessary supporting infrastructure: without them
// a signed-out desktop user would have no way to sign in, recover a
// forgotten password, or complete 2FA.
export const DESKTOP_ALLOWED_ROUTES = [
  '/reader',
  '/account',
  '/signin',
  '/forgot-password',
  '/reset-password',
  '/verify-2fa',
];

// Task 20260929-group-invite-links: routes with a dynamic tail can't be
// listed exactly. Each entry is [prefix, tail pattern]; a pathname is allowed
// only when it is the prefix followed by ONE segment matching the pattern
// (an invite token: 43 url-safe base64 chars), so `/join/` alone, deeper
// paths, or a malformed token all stay denied.
export const DESKTOP_ALLOWED_ROUTE_PATTERNS = [
  /^\/join\/[A-Za-z0-9_-]{43}$/,
];

// Where a disallowed in-app navigation lands. /reader rather than /account
// or /signin, since it's the app's existing post-sign-in landing page
// (SignIn.jsx) and the same page the desktop shell's own webview URL
// (desktop/src-tauri/tauri.conf.json) opens to.
export const DESKTOP_FALLBACK_ROUTE = '/reader';

// Tauri v2 always injects this low-level IPC bridge global on window,
// regardless of the `app.withGlobalTauri` config -- a reliable "are we
// running inside the desktop shell" signal with no tauri.conf.json change
// needed. Evaluates to false in the ordinary web frontend, so every check
// built on this is a no-op there.
export function isDesktopApp() {
  return typeof window !== 'undefined' && typeof window.__TAURI_INTERNALS__ !== 'undefined';
}

export function isAllowedDesktopRoute(pathname) {
  return DESKTOP_ALLOWED_ROUTES.includes(pathname)
    || DESKTOP_ALLOWED_ROUTE_PATTERNS.some((re) => re.test(pathname));
}
