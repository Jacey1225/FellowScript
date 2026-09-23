// @vitest-environment node
//
// Forced to the real Node environment (not this suite's default jsdom --
// see vitest.config.js), matching seo/homeSeo.build.test.js's own reasoning:
// this file invokes a real esbuild-backed `vite build()`, and esbuild's
// environment invariant checks (TextEncoder/Uint8Array) break under jsdom's
// globals.
//
// Regression coverage for task 20260920-fix-spa-crawlability.
//
// The bug this task fixed: a raw (non-JS) HTTP fetch of "/" got back
// `<div id="root"></div>` and nothing else in the body -- Home's real
// content only ever existed after client-side JS executed. seo/
// homeSeo.build.test.js (task 20260914) already proves the <head> tags land
// in the built HTML, but that task never touched the body, so it stayed
// completely empty even after that fix -- exactly the gap Googlebot's raw
// crawl hit for three straight days. Every other *.seo.test.jsx file in
// this repo renders under jsdom and asserts against react-helmet-async's
// client-side head commit, which doesn't exercise the body at all.
//
// This test drives the real production build pipeline end to end -- the
// same two steps `npm run build` runs (see package.json's "build" script):
// a real Vite client build, then the same SSR-bundle-and-splice mechanism
// scripts/prerender.mjs uses -- into scratch output directories (never the
// committed frontend/dist/), and inspects the resulting index.html as plain
// bytes, the same way a non-JS crawler would receive it. This is the one
// test that would catch a regression back to the empty-shell bug: e.g.
// someone removing "&& node scripts/prerender.mjs" from package.json's
// build script, entry-server.jsx's render throwing/producing nothing, or a
// real visitor session leaking into what must stay a signed-out marketing
// snapshot.
//
// Run with: cd frontend && npm test -- --run src/entry-server.build.test.js
import path from 'path';
import fs from 'fs';
import os from 'os';
import { fileURLToPath } from 'url';
import { describe, test, expect, beforeAll, afterAll } from 'vitest';
import { build } from 'vite';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FRONTEND_ROOT = path.resolve(__dirname, '..');
const ROOT_DIV = '<div id="root"></div>';

let clientOutDir;
let ssrOutDir;
let builtHtml; // dist/index.html straight off the plain client `vite build`
let finalHtml; // after prerender's own splice logic runs against it

beforeAll(async () => {
  clientOutDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fellowscript-client-build-'));
  // Unlike clientOutDir above (which is only ever read back as a plain HTML
  // string), this one gets dynamically `import()`-ed below as a real ESM
  // module with bare-specifier imports (react-dom/server, react-router-dom,
  // etc.). Node resolves those by walking up from the importing file's own
  // directory looking for a node_modules -- a plain os.tmpdir() location
  // sits outside this whole project tree and finds none. Scratch dir lives
  // under frontend/ itself instead (same as scripts/prerender.mjs's own
  // dist-ssr/), so that walk-up resolves frontend/node_modules exactly like
  // the real build does.
  ssrOutDir = fs.mkdtempSync(path.join(FRONTEND_ROOT, 'dist-ssr-test-'));

  // Step 1: the ordinary client build (identical to `vite build`, and to
  // seo/homeSeo.build.test.js's own first step) -- produces the bare-shell
  // index.html that existed before this task, into a scratch dir so this
  // suite never clobbers the committed frontend/dist/.
  await build({
    root: FRONTEND_ROOT,
    configFile: path.join(FRONTEND_ROOT, 'vite.config.js'),
    mode: 'production',
    logLevel: 'silent',
    envDir: FRONTEND_ROOT, // load frontend/.env.production for VITE_SITE_URL
    build: { outDir: clientOutDir, write: true, minify: false },
  });

  builtHtml = fs.readFileSync(path.join(clientOutDir, 'index.html'), 'utf8');

  // Step 2: mirrors scripts/prerender.mjs's own SSR-bundle step exactly
  // (same ssr entry, same rollup output naming), just into a scratch outDir
  // instead of the real dist-ssr/.
  await build({
    root: FRONTEND_ROOT,
    configFile: path.join(FRONTEND_ROOT, 'vite.config.js'),
    mode: 'production',
    logLevel: 'silent',
    envDir: FRONTEND_ROOT,
    build: {
      ssr: path.resolve(FRONTEND_ROOT, 'src/entry-server.jsx'),
      outDir: ssrOutDir,
      emptyOutDir: true,
      minify: false,
      rollupOptions: { output: { entryFileNames: 'entry-server.mjs' } },
    },
  });

  const entryPath = path.join(ssrOutDir, 'entry-server.mjs');
  const { renderHome } = await import(`${new URL(`file://${entryPath}`)}?t=${Date.now()}`);
  const homeHtml = renderHome();

  // Same splice prerender.mjs performs against the real dist/index.html.
  finalHtml = builtHtml.replace(ROOT_DIV, `<div id="root">${homeHtml}</div>`);
}, 60000);

afterAll(() => {
  if (clientOutDir) fs.rmSync(clientOutDir, { recursive: true, force: true });
  if (ssrOutDir) fs.rmSync(ssrOutDir, { recursive: true, force: true });
});

describe('production build — Home body content is real, not an empty shell (task 20260920-fix-spa-crawlability)', () => {
  test('documents the bug: the plain client build alone still ships an empty <div id="root">', () => {
    // This is the exact reported symptom -- a raw non-JS fetch of "/" got
    // this and nothing else in the body. Confirms the prerender/splice step
    // below is doing real, necessary work, not covering something already
    // fixed upstream by the client build alone.
    expect(builtHtml).toContain(ROOT_DIV);
  });

  test('after prerendering, the root div is no longer empty and contains real markup', () => {
    expect(finalHtml).not.toContain(ROOT_DIV);
    expect(finalHtml).toMatch(/<div id="root"><[a-z]/);
  });

  test("carries Home's real hero copy -- the actual headline and CTA, not placeholder text", () => {
    // renderToStaticMarkup HTML-escapes text content, so the apostrophe in
    // "don't" comes through as the numeric entity &#x27;, not a literal '.
    expect(finalHtml).toMatch(/You don&#x27;t have to walk with God/);
    expect(finalHtml).toContain('Beautiful Bible Reader');
    // Task 20260923-remove-open-app-button: the top-right header CTA (which
    // read "Get started" signed out, "Open app" signed in) was removed
    // outright, so "Get started" no longer appears anywhere in the
    // prerendered snapshot -- the hero's real CTA copy is "Begin your
    // journey" instead.
    expect(finalHtml).toContain('Begin your journey');
  });

  test('includes real, crawlable body text beyond the hero -- the footer tagline and a link to /download', () => {
    // Task 20260922-reader-nav-download-page: Home's footer "Read" link now
    // points at the new /download page rather than straight into /reader
    // (design-notes.md §4) -- the prerendered signed-out marketing snapshot
    // should reflect that, not the pre-task leaking-nav behavior.
    expect(finalHtml).toContain('Walk with God, together.');
    expect(finalHtml).toMatch(/href="\/download"/);
  });

  test('renders the signed-out snapshot only -- no session-specific "Account" link or "Open app" CTA, since a prerendered marketing snapshot has no real visitor session to reflect', () => {
    expect(finalHtml).not.toMatch(/>Account</);
    expect(finalHtml).not.toContain('Open app');
  });
});

describe('package.json — build script still runs the prerender step (task 20260920-fix-spa-crawlability)', () => {
  test('`npm run build` chains scripts/prerender.mjs after the client build, not just `vite build` alone', () => {
    const pkg = JSON.parse(fs.readFileSync(path.join(FRONTEND_ROOT, 'package.json'), 'utf8'));
    expect(pkg.scripts.build).toMatch(/vite build/);
    expect(pkg.scripts.build).toMatch(/prerender\.mjs/);
  });
});
