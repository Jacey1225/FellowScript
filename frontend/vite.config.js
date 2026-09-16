import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';
import fs from 'fs';
import path from 'path';
import {
  HOME_SEO_PATH,
  HOME_SEO_TITLE,
  HOME_SEO_DESCRIPTION,
  HOME_SEO_IMAGE,
  homeJsonLd,
} from './src/seo/homeSeo.js';

// Custom plugin: serve ../data/* from /data/ in dev
function serveDataDir() {
  return {
    name: 'serve-data-dir',
    configureServer(server) {
      server.middlewares.use('/data', (req, res, next) => {
        const file = path.resolve(__dirname, '../data', req.url.replace(/^\//, ''));
        if (fs.existsSync(file)) {
          const ext = path.extname(file);
          const types = { '.json': 'application/json', '.mp4': 'video/mp4', '.svg': 'image/svg+xml' };
          res.setHeader('Content-Type', types[ext] || 'application/octet-stream');
          fs.createReadStream(file).pipe(res);
        } else {
          next();
        }
      });
    },
  };
}

function escapeAttr(value) {
  return String(value).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function escapeText(value) {
  return String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// Decision (task 20260914-restore-homepage-seo-meta-tags, frontend step):
// bake Home's meta description/OG/Twitter/canonical/JSON-LD directly into
// the *built* index.html's <head> at build time, in addition to (not
// instead of) Seo.jsx's existing client-side react-helmet-async render.
//
// Root cause (full diagnosis in this task's own
// .claude/pipeline/20260914-restore-homepage-seo-meta-tags/backend.json):
// frontend/dist/index.html -- the actual bytes a plain curl/link-unfurler/
// non-JS crawler receives for "/" -- has only ever carried a bare <title>
// since task 20260909-website-seo landed; every other tag it added is
// injected purely client-side by Seo.jsx, invisible without JS execution.
// That was never a fresh deploy regression, just a pre-existing structural
// gap in a client-side-only <head> approach.
//
// This supersedes the *client-side-only* half of 20260909-website-seo's
// HashRouter/no-SSR architecture decision (see App.jsx's Decision comment,
// which still stands otherwise -- HashRouter and no full SSR/prerendering
// pipeline remain the right call at this project's scale, per this task's
// spec explicitly preferring the smallest fix over reopening that). Scoped
// to the Home route only (path === '/'), since under HashRouter the server
// only ever resolves "/" anyway (see App.jsx) -- every other route still
// relies on Seo.jsx alone, unchanged.
//
// Tags are marked data-rh="true" -- react-helmet-async's own
// HELMET_ATTRIBUTE (see node_modules/react-helmet-async/lib/index.js,
// updateTags()) -- so once the app hydrates and Home's <Seo> mounts,
// react-helmet-async recognizes these as tags it already manages and
// reconciles them in place instead of appending a second, duplicate set
// alongside them.
//
// HOME_SEO_*/homeJsonLd() come from src/seo/homeSeo.js, the same
// env/React-agnostic module Home.jsx's client-side <Seo> call now reads
// from too -- one definition of Home's title/description/image/JSON-LD, not
// two copies that could quietly drift apart.
//
// deploy.sh needs no change for this: it already scp's frontend/dist/
// index.html verbatim to the EC2 host (see 20260909-website-seo's
// deploy_gap_found note for the *different* case -- new root-level static
// files -- that one did require a deploy.sh update); this only changes the
// contents of that same existing file, not its shape.
function injectHomeSeoPlugin(siteUrl) {
  return {
    name: 'inject-home-seo',
    apply: 'build',
    transformIndexHtml: {
      order: 'post',
      handler(html) {
        const canonical = `${siteUrl}${HOME_SEO_PATH}`;
        const ogImage = `${siteUrl}${HOME_SEO_IMAGE}`;

        const tags = [
          `<meta name="description" content="${escapeAttr(HOME_SEO_DESCRIPTION)}" data-rh="true">`,
          `<link rel="canonical" href="${escapeAttr(canonical)}" data-rh="true">`,
          `<meta name="robots" content="index, follow" data-rh="true">`,
          `<meta property="og:type" content="website" data-rh="true">`,
          `<meta property="og:title" content="${escapeAttr(HOME_SEO_TITLE)}" data-rh="true">`,
          `<meta property="og:description" content="${escapeAttr(HOME_SEO_DESCRIPTION)}" data-rh="true">`,
          `<meta property="og:url" content="${escapeAttr(canonical)}" data-rh="true">`,
          `<meta property="og:site_name" content="FellowScript" data-rh="true">`,
          `<meta property="og:image" content="${escapeAttr(ogImage)}" data-rh="true">`,
          `<meta name="twitter:card" content="summary_large_image" data-rh="true">`,
          `<meta name="twitter:title" content="${escapeAttr(HOME_SEO_TITLE)}" data-rh="true">`,
          `<meta name="twitter:description" content="${escapeAttr(HOME_SEO_DESCRIPTION)}" data-rh="true">`,
          `<meta name="twitter:image" content="${escapeAttr(ogImage)}" data-rh="true">`,
          ...homeJsonLd(siteUrl).map(
            (block) => `<script type="application/ld+json" data-rh="true">${JSON.stringify(block)}</script>`
          ),
        ].join('\n    ');

        // The static template (frontend/index.html) ships a bare
        // <title>FellowScript</title> placeholder -- swap it for Home's
        // real title so non-JS consumers see the actual page title, not
        // the placeholder. Also carries data-rh="true" so it's consistent
        // with the rest of this set, though react-helmet-async's
        // updateTitle() always targets document.title directly regardless
        // of that attribute.
        return html
          .replace(
            '<title>FellowScript</title>',
            `<title data-rh="true">${escapeText(HOME_SEO_TITLE)}</title>`
          )
          .replace('</head>', `    ${tags}\n  </head>`);
      },
    },
  };
}

export default defineConfig(({ command, mode }) => {
  // Configuration Q4 (fail fast, no implicit defaults), task
  // 20260909-website-seo: VITE_SITE_URL feeds src/config.js's SITE_URL,
  // which drives <link rel="canonical">/Open Graph/JSON-LD across every
  // route. A production build shipped with that missing would silently
  // bake a placeholder/localhost canonical domain into the deployed site,
  // so refuse to build rather than let that happen. Scoped to `build`
  // only -- `npm run dev` doesn't load .env.production and doesn't need
  // this set (src/config.js's dev-only fallback covers it there).
  let siteUrl;
  if (command === 'build') {
    const env = loadEnv(mode, process.cwd(), '');
    if (!env.VITE_SITE_URL) {
      throw new Error(
        'VITE_SITE_URL is required to build the frontend (see frontend/.env.production) -- ' +
        'refusing to build with an implicit/placeholder canonical domain.'
      );
    }
    siteUrl = env.VITE_SITE_URL;
  }

  return {
    plugins: [
      react(),
      serveDataDir(),
      ...(command === 'build' ? [injectHomeSeoPlugin(siteUrl)] : []),
    ],
    build: { outDir: 'dist' },
  };
});
