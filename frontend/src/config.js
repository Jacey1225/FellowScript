// Deployment-specific value (Configuration Q2) -- sourced from Vite's
// build-time env (VITE_API_URL, see frontend/.env) rather than hand-kept in
// sync with frontend/js/config.js's own copy for the no-build legacy pages.
// The literal below is only the local-dev/no-.env fallback, not a second
// canonical value.
export const API     = import.meta.env.VITE_API_URL || 'https://fellowscript.com/api';
export const WS_BASE = API.replace('https://', 'wss://').replace('http://', 'ws://');

// Deployment-specific value (Configuration Q2/Q7) -- the canonical production
// domain used for <link rel="canonical">, Open Graph/Twitter `url` tags, and
// JSON-LD (task 20260909-website-seo). Same VITE_*.env.production convention
// as VITE_API_URL above, but deliberately *without* a soft fallback here:
// per Configuration Q4 (fail fast, no implicit defaults), a production build
// missing this value must fail loudly rather than ship a placeholder/
// localhost canonical URL -- vite.config.js's `command === 'build'` check
// enforces that at build time. The 'http://localhost:5173' fallback below
// only ever runs during `npm run dev` (which doesn't load .env.production
// and isn't covered by that build-time check), exactly mirroring the
// dev-only-fallback framing of the API comment above.
export const SITE_URL = import.meta.env.VITE_SITE_URL || 'http://localhost:5173';
