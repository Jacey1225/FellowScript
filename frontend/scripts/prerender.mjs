#!/usr/bin/env node
// Build-time static prerendering for the Home route (task
// 20260920-fix-spa-crawlability). Run after `vite build` (see package.json's
// "build" script) has already produced frontend/dist/index.html with
// vite.config.js's injectHomeSeoPlugin <head> tags baked in, but still a
// bare, empty `<div id="root"></div>` body -- the actual bytes a non-JS
// crawler fetch of "/" receives before this task. This script replaces that
// empty body with Home's real rendered markup.
//
// Tooling choice (Q29 -- prefer established tooling, vet supply chain before
// adding a dependency): uses Vite's own programmatic build() API (already a
// devDependency, already used the same way by src/seo/homeSeo.build.test.js)
// to bundle src/entry-server.jsx for Node, and react-dom/server's
// renderToStaticMarkup (already in the react-dom dependency tree) to render
// it -- no new third-party SSG/prerender package added.
//
// Scope (see architecture_notes.scope_of_prerendering, task
// 20260920-fix-spa-crawlability): Home only. Privacy/Terms already have real
// page components but are NOT promoted to real (non-fragment) routes in this
// pass -- see App.jsx's Decision comment for why. Every other route
// (Reader, Account, SignIn, admin*, etc.) stays exactly as-is on HashRouter;
// this script never touches those.
import { build, loadEnv } from 'vite';
import {
  DOWNLOAD_SEO_PATH,
  DOWNLOAD_SEO_TITLE,
  DOWNLOAD_SEO_DESCRIPTION,
  DOWNLOAD_SEO_IMAGE,
  DOWNLOAD_ROUTE,
  downloadJsonLd,
} from '../src/seo/downloadSeo.js';
import {
  EXPLORE_SEO_PATH,
  EXPLORE_SEO_TITLE,
  EXPLORE_SEO_DESCRIPTION,
  EXPLORE_SEO_IMAGE,
  EXPLORE_ROUTE,
  exploreJsonLd,
  exploreRobots,
  isExploreBrowseBuildFlagOn,
} from '../src/seo/exploreSeo.js';
import { buildSeoTags, escapeText } from '../src/seo/headTags.js';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '..');
const ssrOutDir = path.resolve(root, 'dist-ssr');
const ROOT_DIV = '<div id="root"></div>';

async function main() {
  const indexPath = path.resolve(root, 'dist/index.html');
  if (!fs.existsSync(indexPath)) {
    throw new Error(
      'prerender.mjs: frontend/dist/index.html not found -- run `vite build` first ' +
      '(see package.json\'s "build" script, which already runs this in the right order).'
    );
  }

  // Bundle src/entry-server.jsx into a throwaway Node-consumable module.
  // Isolated in its own outDir (dist-ssr/) so it never mixes with or
  // clobbers the real client dist/ output that deploy.sh ships; deleted
  // again below once this script is done with it.
  await build({
    root,
    configFile: path.join(root, 'vite.config.js'),
    mode: 'production',
    logLevel: 'warn',
    envDir: root,
    build: {
      ssr: path.resolve(root, 'src/entry-server.jsx'),
      outDir: 'dist-ssr',
      emptyOutDir: true,
      minify: false,
      rollupOptions: { output: { entryFileNames: 'entry-server.mjs' } },
    },
  });

  const entryPath = path.resolve(ssrOutDir, 'entry-server.mjs');
  const { renderHome, renderDownload, renderExplore } = await import(`${new URL(`file://${entryPath}`)}?t=${Date.now()}`);
  const homeHtml = renderHome();

  const html = fs.readFileSync(indexPath, 'utf-8');
  if (!html.includes(ROOT_DIV)) {
    throw new Error(
      `prerender.mjs: expected to find exactly "${ROOT_DIV}" in dist/index.html -- ` +
      'the template shape changed (see frontend/index.html); update this script\'s marker.'
    );
  }

  // Task 20260930-downloads-page-indexable: second real-path page. Built from
  // the pre-Home-splice template so Home's output below is untouched.
  const env = loadEnv('production', root, '');
  if (!env.VITE_SITE_URL) {
    throw new Error('prerender.mjs: VITE_SITE_URL is required (see frontend/.env.production).');
  }
  const siteUrl = env.VITE_SITE_URL;
  const downloadTags = buildSeoTags({
    title: DOWNLOAD_SEO_TITLE,
    description: DOWNLOAD_SEO_DESCRIPTION,
    canonical: `${siteUrl}${DOWNLOAD_SEO_PATH}`,
    ogImage: `${siteUrl}${DOWNLOAD_SEO_IMAGE}`,
    jsonLd: downloadJsonLd(siteUrl),
  });
  // Drop every Home tag the Vite plugin baked in (all carry data-rh="true").
  let downloadHtml = html
    .split('\n')
    .filter((line) => !line.includes('data-rh="true"') || line.includes('<title'))
    .join('\n')
    .replace(/<title data-rh="true">[^<]*<\/title>/, `<title data-rh="true">${escapeText(DOWNLOAD_SEO_TITLE)}</title>`)
    .replace('</head>', `    ${downloadTags}\n  </head>`)
    .replace(ROOT_DIV, `<div id="root">${renderDownload()}</div>`);
  // The same client bundle loads at /download/, where HashRouter would see
  // "/" and render Home. Set the hash (no navigation/redirect) before the
  // bundle runs so the in-app Download route renders at this URL.
  const routeScript = `<script>if(!location.hash){history.replaceState(null,'',location.pathname+location.search+'#${DOWNLOAD_ROUTE}');}</script>`;
  downloadHtml = downloadHtml.replace('<script type="module"', `${routeScript}\n  <script type="module"`);
  const downloadDir = path.resolve(root, 'dist', DOWNLOAD_SEO_PATH.replace(/^\/|\/$/g, ''));
  fs.mkdirSync(downloadDir, { recursive: true });
  fs.writeFileSync(path.join(downloadDir, 'index.html'), downloadHtml);

  // Task 20261008-explore-page-indexable: third real-path page. Indexable only
  // when VITE_EXPLORER_BROWSE is explicitly on at build time; otherwise the
  // file is emitted noindex and not added to the sitemap. Rebuild when the
  // server-side browse flag flips.
  const exploreOn = isExploreBrowseBuildFlagOn(env.VITE_EXPLORER_BROWSE);
  const exploreTags = buildSeoTags({
    title: EXPLORE_SEO_TITLE,
    description: EXPLORE_SEO_DESCRIPTION,
    canonical: `${siteUrl}${EXPLORE_SEO_PATH}`,
    ogImage: `${siteUrl}${EXPLORE_SEO_IMAGE}`,
    jsonLd: exploreJsonLd(siteUrl),
    robots: exploreRobots(exploreOn),
  });
  let exploreHtml = html
    .split('\n')
    .filter((line) => !line.includes('data-rh="true"') || line.includes('<title'))
    .join('\n')
    .replace(/<title data-rh="true">[^<]*<\/title>/, `<title data-rh="true">${escapeText(EXPLORE_SEO_TITLE)}</title>`)
    .replace('</head>', `    ${exploreTags}\n  </head>`)
    .replace(ROOT_DIV, `<div id="root">${renderExplore()}</div>`);
  const exploreRouteScript = `<script>if(!location.hash){history.replaceState(null,'',location.pathname+location.search+'#${EXPLORE_ROUTE}');}</script>`;
  exploreHtml = exploreHtml.replace('<script type="module"', `${exploreRouteScript}\n  <script type="module"`);
  const exploreDir = path.resolve(root, 'dist', EXPLORE_SEO_PATH.replace(/^\/|\/$/g, ''));
  fs.mkdirSync(exploreDir, { recursive: true });
  fs.writeFileSync(path.join(exploreDir, 'index.html'), exploreHtml);

  if (exploreOn) {
    const sitemapPath = path.resolve(root, 'dist/sitemap.xml');
    if (fs.existsSync(sitemapPath)) {
      const sm = fs.readFileSync(sitemapPath, 'utf-8');
      const loc = `${siteUrl}${EXPLORE_SEO_PATH}`;
      if (!sm.includes(`<loc>${loc}</loc>`)) {
        fs.writeFileSync(
          sitemapPath,
          sm.replace('</urlset>', `  <url>\n    <loc>${loc}</loc>\n    <changefreq>weekly</changefreq>\n    <priority>0.6</priority>\n  </url>\n</urlset>`)
        );
      }
    }
  }

  const withHome = html.replace(ROOT_DIV, `<div id="root">${homeHtml}</div>`);
  fs.writeFileSync(indexPath, withHome);

  fs.rmSync(ssrOutDir, { recursive: true, force: true });

  console.log('[prerender] Home prerendered into dist/index.html; downloads page into dist/download/index.html; explore page into dist/explore/index.html (' + (exploreOn ? 'index' : 'noindex') + ')');
}

main().catch((err) => {
  console.error('[prerender] failed:', err);
  process.exit(1);
});
