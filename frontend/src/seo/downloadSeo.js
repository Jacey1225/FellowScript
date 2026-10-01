// Single source of truth for the downloads page's SEO content (task
// 20260930-downloads-page-indexable). Mirrors homeSeo.js: env/React-agnostic
// so vite.config.js / scripts/prerender.mjs (plain Node) and Download.jsx's
// client-side <Seo> all read one definition.
//
// Real, server-resolvable path (trailing slash): the prerender step writes
// dist/download/index.html. The in-app HashRouter route stays "/download"
// (DOWNLOAD_ROUTE) -- that is a fragment route and cannot be indexed.
export const DOWNLOAD_SEO_PATH = '/download/';
export const DOWNLOAD_ROUTE = '/download';

export const DOWNLOAD_SEO_TITLE = 'Download FellowScript — iPhone and Mac apps';

// Truthful: iPhone (App Store) and macOS (DMG) only. Windows is not shipped.
export const DOWNLOAD_SEO_DESCRIPTION =
  'Get FellowScript, the daily Bible reading companion: on the App Store for iPhone, or as a native desktop app for macOS. Windows is coming soon.';

export const DOWNLOAD_SEO_IMAGE = '/og-image.png';

export const APP_STORE_URL = 'https://apps.apple.com/us/app/fellowscript-study-connect/id6791701454';
export const MACOS_DOWNLOAD_URL =
  'https://github.com/Jacey1225/FellowScript/releases/download/desktop-v0.1.0/FellowScript.dmg';

export function downloadJsonLd(siteUrl) {
  const canonical = `${siteUrl}${DOWNLOAD_SEO_PATH}`;
  const free = { '@type': 'Offer', price: '0', priceCurrency: 'USD' };
  return [
    {
      '@context': 'https://schema.org',
      '@type': 'Organization',
      name: 'FellowScript',
      url: siteUrl,
      logo: `${siteUrl}${DOWNLOAD_SEO_IMAGE}`,
    },
    {
      '@context': 'https://schema.org',
      '@type': 'WebPage',
      name: DOWNLOAD_SEO_TITLE,
      url: canonical,
      description: DOWNLOAD_SEO_DESCRIPTION,
    },
    {
      '@context': 'https://schema.org',
      '@type': 'MobileApplication',
      name: 'FellowScript',
      operatingSystem: 'iOS',
      applicationCategory: 'LifestyleApplication',
      downloadUrl: APP_STORE_URL,
      url: canonical,
      offers: free,
    },
    {
      '@context': 'https://schema.org',
      '@type': 'SoftwareApplication',
      name: 'FellowScript for Mac',
      operatingSystem: 'macOS',
      applicationCategory: 'LifestyleApplication',
      downloadUrl: MACOS_DOWNLOAD_URL,
      url: canonical,
      offers: free,
    },
  ];
}
