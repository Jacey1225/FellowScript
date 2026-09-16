// @vitest-environment node
//
// Forced to the real Node environment (not this suite's default jsdom --
// see vitest.config.js) because this file invokes a real esbuild-backed
// `vite build()`, and esbuild's environment invariant checks
// (TextEncoder/Uint8Array) break under jsdom's globals.
//
// Regression coverage for task 20260914-restore-homepage-seo-meta-tags.
//
// Every other *.seo.test.jsx file in this repo (Home.seo.test.jsx,
// App.route-seo.test.jsx, Seo.test.jsx) renders components under jsdom and
// asserts against the *client-side* react-helmet-async commit to
// document.head. That coverage was never actually broken by this bug --
// per this task's own backend.json diagnosis, the real gap was that
// frontend/dist/index.html (the literal bytes a non-JS curl/link-unfurler/
// crawler receives for "/") never carried these tags at all, because they
// were only ever injected client-side after JS execution.
//
// This test instead runs a real production `vite build` (via Vite's own
// build() API, exactly like `npm run build`/deploy.sh does) and inspects
// the resulting index.html as a plain string -- no jsdom, no React render,
// no Helmet commit -- to prove the fix (vite.config.js's
// injectHomeSeoPlugin) actually lands these tags in the served bytes
// themselves. This is the one test in the suite that would catch a
// regression back to "only client-side rendering," e.g. someone removing
// injectHomeSeoPlugin from vite.config.js's plugins array, or a future
// edit to homeSeo.js that isn't reflected in the built output.
//
// Slower than the rest of the suite (a real bundle build, ~a few seconds)
// -- deliberately isolated to its own file so `npm test` can still target
// the fast jsdom suites separately if needed.
//
// Run with: cd frontend && npm test -- --run src/seo/homeSeo.build.test.js
import path from 'path';
import fs from 'fs';
import os from 'os';
import { fileURLToPath } from 'url';
import { describe, test, expect, beforeAll, afterAll } from 'vitest';
import { build } from 'vite';
import {
  HOME_SEO_TITLE,
  HOME_SEO_DESCRIPTION,
  homeJsonLd,
} from './homeSeo.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FRONTEND_ROOT = path.resolve(__dirname, '../..');
const SITE_URL = 'https://fellowscript.com';

let outDir;
let html;

beforeAll(async () => {
  // Build into a scratch directory rather than the committed dist/ so this
  // test doesn't clobber that build artifact as a side effect of running
  // the suite.
  outDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fellowscript-seo-build-'));

  await build({
    root: FRONTEND_ROOT,
    configFile: path.join(FRONTEND_ROOT, 'vite.config.js'),
    mode: 'production',
    logLevel: 'silent',
    envDir: FRONTEND_ROOT, // load frontend/.env.production for VITE_SITE_URL
    build: { outDir, write: true, minify: false },
  });

  html = fs.readFileSync(path.join(outDir, 'index.html'), 'utf8');
}, 30000);

afterAll(() => {
  if (outDir) fs.rmSync(outDir, { recursive: true, force: true });
});

describe('production build — Home <head> tags are in the served bytes, not just client-side (task 20260914-restore-homepage-seo-meta-tags)', () => {
  test('does not regress to the bare placeholder title with no other tags', () => {
    // This is literally the reported bug: at task 20260909-website-seo's
    // commit, built index.html contained only this one line in <head>
    // beyond boilerplate. Guard against ever shipping that again.
    expect(html).not.toMatch(/<title>FellowScript<\/title>/);
    expect(html).toMatch(/<title[^>]*>FellowScript/);
  });

  test('real title and meta description are present in the raw HTML', () => {
    expect(html).toContain(`<title data-rh="true">${HOME_SEO_TITLE}</title>`);
    expect(html).toMatch(
      new RegExp(`<meta name="description" content="${escapeRe(HOME_SEO_DESCRIPTION)}"`)
    );
  });

  test('canonical link and robots tag point at the real production domain', () => {
    expect(html).toContain(`<link rel="canonical" href="${SITE_URL}/" data-rh="true">`);
    expect(html).toContain('<meta name="robots" content="index, follow" data-rh="true">');
  });

  test('Open Graph tags are present with the real brand image, not a placeholder', () => {
    expect(html).toContain('<meta property="og:type" content="website" data-rh="true">');
    expect(html).toContain(`<meta property="og:title" content="${HOME_SEO_TITLE}" data-rh="true">`);
    expect(html).toContain(`<meta property="og:url" content="${SITE_URL}/" data-rh="true">`);
    expect(html).toContain(`<meta property="og:image" content="${SITE_URL}/data/logo.png" data-rh="true">`);
  });

  test('Twitter Card tags are present', () => {
    expect(html).toContain('<meta name="twitter:card" content="summary_large_image" data-rh="true">');
    expect(html).toContain(`<meta name="twitter:title" content="${HOME_SEO_TITLE}" data-rh="true">`);
    expect(html).toContain(`<meta name="twitter:image" content="${SITE_URL}/data/logo.png" data-rh="true">`);
  });

  test('Organization + WebSite JSON-LD blocks are present and match homeSeo.js exactly', () => {
    const blocks = homeJsonLd(SITE_URL).map((b) => JSON.stringify(b));
    for (const block of blocks) {
      expect(html).toContain(`<script type="application/ld+json" data-rh="true">${block}</script>`);
    }
  });

  test('every injected tag carries data-rh="true" so client-side react-helmet-async reconciles rather than duplicates', () => {
    const headMatch = html.match(/<head>[\s\S]*<\/head>/);
    expect(headMatch).toBeTruthy();
    const head = headMatch[0];

    // Every meta/link/script tag this plugin injects should be tagged
    // data-rh="true" (react-helmet-async's own HELMET_ATTRIBUTE) so its
    // client-side updateTags() reconciliation (isEqualNode match) finds and
    // keeps them instead of appending a second, duplicate set once Home's
    // <Seo> mounts.
    const injectedDescriptionCount = (head.match(/<meta name="description"/g) || []).length;
    expect(injectedDescriptionCount).toBe(1);
    expect(head).toMatch(/<meta name="description"[^>]*data-rh="true"/);
  });
});

function escapeRe(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
