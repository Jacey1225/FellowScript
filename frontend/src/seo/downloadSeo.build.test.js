// @vitest-environment node
//
// Task 20260930-downloads-page-indexable. Runs the real `npm run build`
// (vite build + scripts/prerender.mjs) and inspects dist/download/index.html
// and dist/index.html as raw bytes, the way a non-JS crawler would see them.
//
// Run with: cd frontend && npm test -- --run src/seo/downloadSeo.build.test.js
import path from 'path';
import fs from 'fs';
import { execSync } from 'child_process';
import { fileURLToPath } from 'url';
import { describe, test, expect, beforeAll } from 'vitest';
import {
  DOWNLOAD_SEO_TITLE,
  DOWNLOAD_SEO_DESCRIPTION,
  APP_STORE_URL,
  MACOS_DOWNLOAD_URL,
  downloadJsonLd,
} from './downloadSeo.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FRONTEND_ROOT = path.resolve(__dirname, '../..');
const SITE = 'https://fellowscript.com';

let dl;
let home;

beforeAll(() => {
  execSync('npm run build', { cwd: FRONTEND_ROOT, stdio: 'pipe' });
  dl = fs.readFileSync(path.join(FRONTEND_ROOT, 'dist/download/index.html'), 'utf8');
  home = fs.readFileSync(path.join(FRONTEND_ROOT, 'dist/index.html'), 'utf8');
}, 240000);

const escTitle = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

describe('dist/download/index.html (raw, no JS)', () => {
  test('has the unique title, description and canonical with trailing slash', () => {
    expect(dl).toContain(`<title data-rh="true">${escTitle(DOWNLOAD_SEO_TITLE)}</title>`);
    expect(dl).toContain(`href="${SITE}/download/"`);
    expect(dl).toMatch(/rel="canonical"/);
    expect(dl).toContain('name="description"');
    expect(dl).toContain('Windows is coming soon');
    expect(DOWNLOAD_SEO_DESCRIPTION).toMatch(/App Store/);
  });

  test('robots is index, follow; OG and Twitter tags present', () => {
    expect(dl).toMatch(/name="robots"\s+content="index, follow"/);
    expect(dl).not.toMatch(/noindex/i);
    expect(dl).toContain('property="og:title"');
    expect(dl).toContain('property="og:url"');
    expect(dl).toContain('name="twitter:card"');
    expect(dl).toContain(`${SITE}/og-image.png`);
  });

  test('carries no Home head tags (single title, single canonical, Home canonical absent)', () => {
    expect((dl.match(/<title/g) || []).length).toBe(1);
    expect((dl.match(/rel="canonical"/g) || []).length).toBe(1);
    expect(dl).not.toContain(`href="${SITE}/"`);
    expect(dl).not.toMatch(/Lead with confidence/);
  });

  test('body has real content with App Store and DMG links, not an empty shell', () => {
    expect(dl).not.toContain('<div id="root"></div>');
    expect(dl).toMatch(/<div id="root"><[a-z]/);
    expect(dl).toContain(`href="${APP_STORE_URL}"`);
    expect(dl).toContain(`href="${MACOS_DOWNLOAD_URL}"`);
  });

  test('hash-route script sets #/download before the module bundle so Home never renders', () => {
    const scriptIdx = dl.indexOf("replaceState(null,'',location.pathname+location.search+'#/download')");
    const moduleIdx = dl.indexOf('<script type="module"');
    expect(scriptIdx).toBeGreaterThan(-1);
    expect(moduleIdx).toBeGreaterThan(scriptIdx);
  });

  test('JSON-LD in the built page parses and matches the shared source, with no Windows download claim', () => {
    const blocks = Array.from(dl.matchAll(/<script[^>]*type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/g));
    expect(blocks.length).toBeGreaterThan(0);
    const parsed = blocks.flatMap((m) => {
      const v = JSON.parse(m[1]);
      return Array.isArray(v) ? v : [v];
    });
    expect(parsed).toEqual(downloadJsonLd(SITE));
    const types = parsed.map((p) => p['@type']);
    expect(types).toEqual(expect.arrayContaining(['Organization', 'WebPage', 'MobileApplication', 'SoftwareApplication']));
    const urls = parsed.map((p) => p.downloadUrl).filter(Boolean);
    expect(urls.sort()).toEqual([APP_STORE_URL, MACOS_DOWNLOAD_URL].sort());
    expect(parsed.some((p) => /windows/i.test(p.operatingSystem || ''))).toBe(false);
    expect(JSON.stringify(parsed.map((p) => p.downloadUrl))).not.toMatch(/windows|\.exe|\.msi/i);
  });
});

describe('dist/index.html (Home regression)', () => {
  test('keeps Home canonical, index/follow, prerendered hero, and no download-page tags', () => {
    expect(home).toContain(`href="${SITE}/"`);
    expect(home).toMatch(/name="robots"\s+content="index, follow"/);
    expect(home).toMatch(/Lead with confidence/);
    expect(home).not.toContain(escTitle(DOWNLOAD_SEO_TITLE));
    expect(home).not.toContain(`href="${SITE}/download/"`.replace('href=', 'rel="canonical" href='));
    expect(home).not.toContain("#/download')");
  });

  test('Home footer has a plain crawlable link to /download/', () => {
    expect(home).toMatch(/<a [^>]*href="\/download\/"/);
  });
});
