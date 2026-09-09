import React from 'react';
import { Helmet, HelmetProvider } from 'react-helmet-async';
import { SITE_URL } from '../config.js';

// Per-route <head> metadata (task 20260909-website-seo). Built on
// react-helmet-async rather than a hand-rolled document.title/meta-tag
// mutation, per Architecture Q29 (prefer an established library even if the
// dependency tree grows) -- it declaratively merges/replaces tags per
// mounted route and is the actively-maintained fork of the (now
// unmaintained) original react-helmet, matching this SPA's client-side
// routing model without needing SSR.
//
// Every route renders this with at least a title; `path` should be the
// route's real in-app path (e.g. '/privacy') so the canonical URL and OG
// `url` tag point at a real, navigable route. `noindex` is for
// authenticated/app routes that shouldn't be indexed even though they still
// deserve a real tab title (Home.jsx / App.jsx routing decision notes) --
// see the HashRouter limitation documented in App.jsx and robots.txt: the
// server only ever resolves "/", so this is best-effort/defense-in-depth
// rather than a guarantee those routes are unreachable by crawlers today.
export default function Seo({
  title,
  description,
  path = '/',
  noindex = false,
  image,
  type = 'website',
  jsonLd,
}) {
  const canonical = `${SITE_URL}${path}`;
  const ogImage = image ? `${SITE_URL}${image}` : undefined;
  const jsonLdBlocks = jsonLd ? (Array.isArray(jsonLd) ? jsonLd : [jsonLd]) : [];

  // Self-contained HelmetProvider (rather than requiring one further up the
  // tree, e.g. in main.jsx) so every page that renders <Seo> works
  // standalone -- including this codebase's existing per-page *.test.jsx
  // files, which mount pages like Home/Account/SignIn directly under just
  // a MemoryRouter, with no knowledge of an SEO-specific provider
  // requirement. react-helmet-async still commits to the real document
  // <head> regardless of which provider instance owns a given <Helmet>, so
  // this doesn't change production behavior -- routes never render more
  // than one <Seo> at a time.
  return (
    <HelmetProvider>
    <Helmet>
      <title>{title}</title>
      {description && <meta name="description" content={description} />}
      <link rel="canonical" href={canonical} />
      <meta name="robots" content={noindex ? 'noindex, nofollow' : 'index, follow'} />

      {/* Open Graph */}
      <meta property="og:type" content={type} />
      <meta property="og:title" content={title} />
      {description && <meta property="og:description" content={description} />}
      <meta property="og:url" content={canonical} />
      <meta property="og:site_name" content="FellowScript" />
      {ogImage && <meta property="og:image" content={ogImage} />}

      {/* Twitter Card */}
      <meta name="twitter:card" content={ogImage ? 'summary_large_image' : 'summary'} />
      <meta name="twitter:title" content={title} />
      {description && <meta name="twitter:description" content={description} />}
      {ogImage && <meta name="twitter:image" content={ogImage} />}

      {jsonLdBlocks.map((block, i) => (
        <script key={i} type="application/ld+json">{JSON.stringify(block)}</script>
      ))}
    </Helmet>
    </HelmetProvider>
  );
}
