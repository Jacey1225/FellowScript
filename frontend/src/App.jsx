import React from 'react';
import { HashRouter, Routes, Route, Navigate } from 'react-router-dom';
import Home from './pages/Home.jsx';
import Reader from './pages/Reader.jsx';
import Account from './pages/Account.jsx';
import SignIn from './pages/SignIn.jsx';
import ForgotPassword from './pages/ForgotPassword.jsx';
import ResetPassword from './pages/ResetPassword.jsx';
import VerifyMfa from './pages/VerifyMfa.jsx';
import Privacy from './pages/Privacy.jsx';
import Terms from './pages/Terms.jsx';
import Download from './pages/Download.jsx';
import AdminGate from './components/AdminGate.jsx';
import MobileBlockGate from './components/MobileBlockGate.jsx';
import DesktopRouteGuard from './components/DesktopRouteGuard.jsx';
import VisitTracker from './components/VisitTracker.jsx';
import AdminDetections from './pages/AdminDetections.jsx';
import AdminDetectionDetail from './pages/AdminDetectionDetail.jsx';

export default function App() {
  return (
    // Decision (task 20260909-website-seo, architecture step): keep
    // HashRouter -- do NOT migrate to BrowserRouter, and do not add
    // SSR/prerendering. Rationale:
    //  1. BrowserRouter's clean URLs need a server-side SPA-fallback
    //     rewrite rule so deep links resolve on refresh; no nginx or any
    //     other static-hosting config is checked into this repo (see
    //     deploy.sh -- it only rsyncs dist/assets/ and scp's index.html to
    //     the EC2 host), so that rewrite rule lives entirely on a host
    //     outside this repo's reach and can't be implemented or verified
    //     from here.
    //  2. This is a solo-maintained marketing site with one real content
    //     page (Home). A router migration or a parallel SSR/prerendering
    //     pipeline is disproportionate complexity for an SEO-polish task,
    //     not earned by current scale.
    // Consequence (documented here + in robots.txt/sitemap.xml): under
    // HashRouter, the server only ever resolves the path "/" --
    // /#/privacy, /#/terms, /#/reader etc. all live after the "#" fragment,
    // which crawlers never send to the server. robots.txt Disallow rules
    // can't match against them. Revisit this decision if the site ever
    // needs more than one crawlable marketing page.
    //
    // Decision update (task 20260914-restore-homepage-seo-meta-tags): the
    // "client-side <head> only" half of the HashRouter decision above
    // wasn't actually visible to non-JS consumers on Home; fixed via
    // build-time tag injection into index.html (see vite.config.js's
    // injectHomeSeoPlugin), not by reopening HashRouter/SSR, which stands.
    //
    // Decision update (task 20260918-fix-google-indexing-audit): sitemap.xml
    // no longer lists /#/privacy or /#/terms -- they were never independently
    // crawlable fragment URLs under HashRouter (see this file's own note
    // above) and had no real static-route equivalent to repoint at instead,
    // so they were dead sitemap entries rather than a genuine indexing aid.
    // Removing them doesn't reopen the HashRouter decision itself, which
    // still stands for the reasons above.
    //
    // Decision update (task 20260920-fix-spa-crawlability): the three-day
    // zero-`site:` outcome confirmed the risk this file's original Decision
    // comment above accepted -- Googlebot's raw HTML fetch of "/" really did
    // carry no crawlable body content, only the SEO <head> tags task
    // 20260914-restore-homepage-seo-meta-tags added. Fixed via build-time
    // static prerendering of the Home route only (see
    // frontend/src/entry-server.jsx + frontend/scripts/prerender.mjs, wired
    // into `npm run build` in package.json): react-dom/server's
    // renderToStaticMarkup renders Home's real markup into dist/index.html's
    // `<div id="root">` after the ordinary Vite build, so a non-JS fetch of
    // "/" now gets real body content, not an empty shell. The live app still
    // mounts via `createRoot(...).render()` in main.jsx exactly as before,
    // which replaces that snapshot with the interactive app on load -- this
    // is a one-time static snapshot for crawlers/non-JS clients, not a
    // hydration target.
    //
    // This does NOT reopen full SSR or a HashRouter->BrowserRouter
    // migration, both still rejected for the reasons in the original
    // Decision comment above (no in-repo server-rewrite config; the current
    // deploy model ships static files only). Build-time prerendering
    // sidesteps that constraint entirely -- it produces a real physical HTML
    // file, which the existing static file server resolves with no rewrite
    // rule and no new running process.
    //
    // Privacy/Terms are deliberately NOT promoted to real (non-fragment)
    // routes in this pass. Doing so while every other route stays on
    // HashRouter would mean the client bundle mounts under HashRouter (which
    // reads the URL fragment, defaulting to "/") while a prerendered
    // /privacy or /terms path-based URL would exist server-side with no
    // fragment -- the app would silently render Home instead of the
    // requested page once JS took over, a real client-side regression for
    // the sake of two low-traffic static pages. HashRouter therefore stays
    // for every route, including these two, exactly as the original
    // Decision above already had it; robots.txt/sitemap.xml are unchanged by
    // this task since no route actually became newly crawlable besides "/",
    // which was already the one path the server ever resolved.
    <HashRouter>
      {/* Task 20260918-admin-activity-monitoring: fires the visit-tracking
          beacon on every route change. Mounted here (inside the router, but
          outside DesktopRouteGuard/Routes) so it sees every navigation via
          useLocation() exactly once, regardless of which route ends up
          rendering below -- it no-ops entirely inside the Tauri desktop
          shell (see VisitTracker.jsx). Renders nothing. */}
      <VisitTracker />
      {/* Restricts the Tauri desktop shell to lib/desktopScope.js's
          DESKTOP_ALLOWED_ROUTES (task 20260906-desktop-scope-lockdown); a
          no-op in the ordinary web frontend. See DesktopRouteGuard.jsx. */}
      <DesktopRouteGuard>
        <Routes>
          <Route path="/"       element={<Home />} />
          <Route path="/reader" element={<MobileBlockGate><Reader /></MobileBlockGate>} />
          {/* Task 20260922-reader-nav-download-page: the single "go get the
              app" destination every leaking nav occurrence into /reader now
              routes to instead. Deliberately not on DESKTOP_ALLOWED_ROUTES
              (desktopScope.js) — a web-marketing-site concern, not something
              the Tauri shell should ever navigate into (design-notes.md §6). */}
          <Route path="/download"  element={<Download />} />
          <Route path="/account"   element={<Account />} />
          <Route path="/signin"    element={<SignIn />} />
          <Route path="/forgot-password" element={<ForgotPassword />} />
          <Route path="/reset-password"  element={<ResetPassword />} />
          <Route path="/verify-2fa"      element={<VerifyMfa />} />
          <Route path="/privacy"   element={<Privacy />} />
          <Route path="/terms"     element={<Terms />} />
          {/* Hidden admin-only surface: not linked from AppNav or any other
              nav/menu component. Reachable only by navigating to the URL
              directly. Server-side `require_admin` is the real enforcement;
              AdminGate is defense-in-depth UX only. See design-notes.md §0. */}
          <Route path="/admin" element={<AdminGate><AdminDetections /></AdminGate>} />
          <Route path="/admin/detections/:id" element={<AdminGate><AdminDetectionDetail /></AdminGate>} />
          <Route path="*"          element={<Navigate to="/" replace />} />
        </Routes>
      </DesktopRouteGuard>
    </HashRouter>
  );
}
