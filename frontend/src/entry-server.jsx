import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { StaticRouter } from 'react-router-dom';
import { AuthProvider } from './context/AuthContext.jsx';
import Home from './pages/Home.jsx';

// Build-time-only entry point (task 20260920-fix-spa-crawlability). Loaded
// exclusively by scripts/prerender.mjs, after the ordinary client
// `vite build`, to turn Home's real component tree into a real HTML string
// via react-dom/server's renderToStaticMarkup -- the official, already-in-
// dependency-tree mechanism for this (Q29: prefer established tooling over
// a hand-rolled snapshot script), rather than a new prerender/SSG plugin.
//
// This is never imported by the live client bundle (main.jsx doesn't touch
// this file) and is never shipped -- see scripts/prerender.mjs, which
// bundles this file to a throwaway dist-ssr/ directory, uses it once, then
// deletes that directory. deploy.sh's ship list is unaffected.
//
// StaticRouter (react-router-dom's own server-rendering router, not a
// third-party addition) stands in for the live app's HashRouter here only
// so Home's <Link> elements have a router context to resolve against during
// this one-off render. It does not replace HashRouter for the live app --
// see App.jsx's Decision comment -- and the output below is a static
// snapshot spliced into dist/index.html's <div id="root">, not a hydration
// target: main.jsx still mounts the real app with `createRoot(...).render()`
// exactly as before, which replaces this snapshot with the live,
// interactive app as soon as the client bundle runs. Real users on a
// reasonable connection won't perceive the difference; what changes is what
// a non-JS HTTP fetch (Googlebot's initial crawl, link unfurlers, etc.)
// receives for "/".
//
// Rendered signed-out (AuthProvider's own default state -- see
// AuthContext.jsx's getStoredUser(), which safely returns null when
// sessionStorage/localStorage don't exist in this Node build context) since
// a prerendered marketing snapshot has no real visitor session to reflect;
// this matches what an actual anonymous crawler would see regardless.
export function renderHome() {
  return renderToStaticMarkup(
    <StaticRouter location="/">
      <AuthProvider>
        <Home />
      </AuthProvider>
    </StaticRouter>
  );
}
