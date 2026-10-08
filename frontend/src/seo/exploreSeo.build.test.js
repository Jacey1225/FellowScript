// @vitest-environment node
//
// Task 20261008-explore-page-indexable. Runs the real build + scripts/prerender.mjs
// against a throwaway COPY of the frontend sources (flag on and flag off) so the
// committed frontend/dist is never touched. Inspects raw bytes as a crawler would.
//
// Run with: cd frontend && npm test -- --run src/seo/exploreSeo.build.test.js
import path from 'path';
import fs from 'fs';
import { execSync } from 'child_process';
import { fileURLToPath } from 'url';
import { describe, test, expect, beforeAll, afterAll } from 'vitest';
import { exploreJsonLd, EXPLORE_SEO_TITLE } from './exploreSeo.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FRONTEND_ROOT = path.resolve(__dirname, '../..');
const SITE = 'https://fellowscript.com';
const dirs = [];

function buildCopy(flag) {
  const dir = fs.mkdtempSync(path.join(FRONTEND_ROOT, `.explore-build-${flag ? 'on' : 'off'}-`));
  dirs.push(dir);
  for (const f of ['src', 'public', 'scripts']) fs.cpSync(path.join(FRONTEND_ROOT, f), path.join(dir, f), { recursive: true });
  for (const f of ['index.html', 'vite.config.js', 'package.json', '.env.production']) fs.copyFileSync(path.join(FRONTEND_ROOT, f), path.join(dir, f));
  fs.symlinkSync(path.join(FRONTEND_ROOT, 'node_modules'), path.join(dir, 'node_modules'));
  // The real .env.production now ships the flag on; strip it so "off" really is off.
  const envPath = path.join(dir, '.env.production');
  fs.writeFileSync(envPath, fs.readFileSync(envPath, 'utf-8').split('\n').filter((l) => !l.startsWith('VITE_EXPLORER_BROWSE=')).join('\n'));
  if (flag) fs.appendFileSync(envPath, '\nVITE_EXPLORER_BROWSE=true\n');
  execSync('npx vite build && node scripts/prerender.mjs', { cwd: dir, stdio: 'pipe' });
  const rd = (p) => fs.readFileSync(path.join(dir, 'dist', p), 'utf8');
  return { explore: rd('explore/index.html'), home: rd('index.html'), download: rd('download/index.html'), sitemap: rd('sitemap.xml') };
}

let on;
let off;
beforeAll(() => { off = buildCopy(false); on = buildCopy(true); }, 400000);
afterAll(() => { for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });

describe('dist/explore/index.html flag on', () => {
  test('head: unique title, canonical, index/follow, OG/Twitter', () => {
    expect(on.explore).toContain(`<title data-rh="true">${EXPLORE_SEO_TITLE.replace(/&/g, '&amp;')}</title>`);
    expect(on.explore).toContain(`href="${SITE}/explore/"`);
    expect(on.explore).toMatch(/name="robots"\s+content="index, follow"/);
    expect(on.explore).not.toMatch(/noindex/i);
    expect(on.explore).toContain('property="og:title"');
    expect(on.explore).toContain('name="twitter:card"');
    expect((on.explore.match(/<title/g) || []).length).toBe(1);
    expect((on.explore.match(/rel="canonical"/g) || []).length).toBe(1);
    expect(on.explore).not.toMatch(/Lead with confidence/);
  });
  test('body is real content, JSON-LD parses and matches source', () => {
    expect(on.explore).not.toContain('<div id="root"></div>');
    expect(on.explore).toMatch(/<div id="root"><[a-z]/);
    expect(on.explore).toContain('Explore groups');
    const blocks = Array.from(on.explore.matchAll(/<script[^>]*type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/g));
    const parsed = blocks.flatMap((m) => { const v = JSON.parse(m[1]); return Array.isArray(v) ? v : [v]; });
    expect(parsed).toEqual(exploreJsonLd(SITE));
  });
  test('hash-route script precedes the module bundle', () => {
    const s = on.explore.indexOf("replaceState(null,'',location.pathname+location.search+'#/explore')");
    expect(s).toBeGreaterThan(-1);
    expect(on.explore.indexOf('<script type="module"')).toBeGreaterThan(s);
  });
  test('sitemap advertises /explore/ exactly once', () => {
    expect(on.sitemap.split(`<loc>${SITE}/explore/</loc>`).length - 1).toBe(1);
    expect(on.sitemap).toContain(`<loc>${SITE}/</loc>`);
    expect(on.sitemap).toContain(`<loc>${SITE}/download/</loc>`);
    expect(on.sitemap).toMatch(/<\/urlset>\s*$/);
  });
});

describe('dist/explore/index.html flag off (default)', () => {
  test('noindex, nofollow and not in sitemap', () => {
    expect(off.explore).toMatch(/name="robots"\s+content="noindex, nofollow"/);
    expect(off.explore).not.toMatch(/content="index, follow"/);
    expect(off.sitemap).not.toContain('/explore');
  });
  test('still has real body content', () => {
    expect(off.explore).toMatch(/<div id="root"><[a-z]/);
  });
});

describe('Home/Download regression', () => {
  test('Home and Download output are identical regardless of the explore flag', () => {
    // The env flag changes the JS bundle's content hash; normalize it.
    const norm = (h) => h.replace(/\/assets\/index-[\w-]+\.js/g, '/assets/index-HASH.js');
    expect(norm(on.home)).toBe(norm(off.home));
    expect(norm(on.download)).toBe(norm(off.download));
  });
  test('Home keeps canonical, index/follow, hero; Download keeps its tags and has no explore tags', () => {
    expect(on.home).toContain(`href="${SITE}/"`);
    expect(on.home).toMatch(/name="robots"\s+content="index, follow"/);
    expect(on.home).toMatch(/Lead with confidence/);
    expect(on.home).not.toContain("#/explore')");
    expect(on.download).toContain(`href="${SITE}/download/"`);
    expect(on.download).toMatch(/name="robots"\s+content="index, follow"/);
    expect(on.download).not.toContain(`${SITE}/explore/`);
    expect(on.download).toContain("#/download')");
  });
});
