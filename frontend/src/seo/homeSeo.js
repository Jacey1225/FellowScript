// Single source of truth for the Home route's SEO content (task
// 20260914-restore-homepage-seo-meta-tags).
//
// Root cause this exists to fix (see this task's own paperwork at
// .claude/pipeline/20260914-restore-homepage-seo-meta-tags/backend.json for
// the full diagnosis): frontend/dist/index.html -- the actual bytes a
// non-JS-executing curl/link-unfurler/crawler ever sees for "/" -- has only
// ever carried a bare <title>. Every tag task 20260909-website-seo added
// (meta description/OG/Twitter/canonical/JSON-LD, via Seo.jsx +
// react-helmet-async) is injected purely client-side at runtime, so it was
// never actually visible to anything that doesn't execute JS -- not a fresh
// deploy regression, a pre-existing structural gap. This module is what lets
// vite.config.js's build-time <head> injection (see its own Decision
// comment) and Home.jsx's client-side <Seo> render share exactly one
// definition of Home's title/description/image/JSON-LD instead of two that
// could quietly drift apart.
//
// Deliberately framework/env-agnostic -- no React import, and no direct read
// of `import.meta.env` (that stays in src/config.js) -- so this module also
// imports cleanly from vite.config.js, a plain Node/ESM context outside
// Vite's client bundling, at build time. `homeJsonLd` takes the resolved
// SITE_URL as a parameter for the same reason: Home.jsx passes in
// src/config.js's SITE_URL (client build), and vite.config.js passes in the
// same VITE_SITE_URL value it already loads/validates for the production
// build (Configuration Q4 fail-fast), rather than each side re-deriving it
// differently.
export const HOME_SEO_PATH = '/';

export const HOME_SEO_TITLE = 'FellowScript — Walk with God, Together';

export const HOME_SEO_DESCRIPTION =
  'A daily Bible reading companion with verse highlights, personal notes, gentle AI check-ins, and real-time group study — walk with God, together.';

export const HOME_SEO_IMAGE = '/data/logo.png';

// Structured data (originally task 20260909-website-seo) -- Organization +
// WebSite, the minimal JSON-LD pair recommended for a small brand's
// marketing home page. logo points at the existing data/logo.png brand
// asset rather than a newly-produced OG image; no design gate involvement
// needed for this task either.
export function homeJsonLd(siteUrl) {
  return [
    {
      '@context': 'https://schema.org',
      '@type': 'Organization',
      name: 'FellowScript',
      url: siteUrl,
      logo: `${siteUrl}${HOME_SEO_IMAGE}`,
    },
    {
      '@context': 'https://schema.org',
      '@type': 'WebSite',
      name: 'FellowScript',
      url: siteUrl,
    },
  ];
}
