// Single source of truth for the Explore landing page's SEO content (task
// 20261008-explore-page-indexable). Mirrors downloadSeo.js: env/React-agnostic
// so scripts/prerender.mjs (plain Node) and Explore.jsx's client <Seo> share it.
//
// Real, server-resolvable path (trailing slash): the prerender step writes
// dist/explore/index.html. The in-app HashRouter route stays "/explore"
// (EXPLORE_ROUTE). Only this landing page is indexable; /explore/manage,
// /explore/requests and /explore/:publicId are not.
export const EXPLORE_SEO_PATH = '/explore/';
export const EXPLORE_ROUTE = '/explore';

export const EXPLORE_SEO_TITLE = 'Explore groups — FellowScript';

// Truthful, generic: no listing counts or named groups.
export const EXPLORE_SEO_DESCRIPTION =
  'Browse FellowScript groups and find one near your faith and season of life. Filter by denomination, meeting format, and location.';

export const EXPLORE_SEO_IMAGE = '/og-image.png';

// Build-time flag. Indexing is opt-in: anything other than an explicit
// "true"/"1" means noindex. The server-side flag cannot be read by static
// HTML, so the build must be redone when the server flag flips.
export function isExploreBrowseBuildFlagOn(value) {
  const v = String(value ?? '').trim().toLowerCase();
  return v === 'true' || v === '1';
}

export function exploreRobots(flagOn) {
  return flagOn ? 'index, follow' : 'noindex, nofollow';
}

export function exploreJsonLd(siteUrl) {
  return [
    {
      '@context': 'https://schema.org',
      '@type': 'CollectionPage',
      name: EXPLORE_SEO_TITLE,
      url: `${siteUrl}${EXPLORE_SEO_PATH}`,
      description: EXPLORE_SEO_DESCRIPTION,
      isPartOf: { '@type': 'WebSite', name: 'FellowScript', url: siteUrl },
    },
  ];
}
