// Confirms frontend/public/robots.txt and sitemap.xml satisfy this task's
// acceptance criteria end-to-end (task 20260909-website-seo): deny-by-default
// crawl posture, a sitemap pointer, only genuinely public routes listed, and
// -- critically -- that neither file ever names the unlinked /admin surface
// (Security Posture Q2; the exact regression the security gate reviewed for:
// a naive "Disallow: /admin" would itself announce it). Also confirms
// deploy.sh actually ships both files, closing the deploy gap architecture
// flagged (Vite copies frontend/public/* into dist/, but deploy.sh only
// synced assets/ and index.html before this task).
//
// Run with: cd frontend && npm test -- --run src/robots-sitemap.test.js
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { describe, test, expect } from 'vitest';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(__dirname, '../public');
const REPO_ROOT = path.join(__dirname, '../..');

const robots = fs.readFileSync(path.join(PUBLIC_DIR, 'robots.txt'), 'utf8');
const sitemap = fs.readFileSync(path.join(PUBLIC_DIR, 'sitemap.xml'), 'utf8');

describe('robots.txt', () => {
  test('deny-by-default: a catch-all Disallow: / plus explicit Allow for the public marketing routes', () => {
    expect(robots).toMatch(/User-agent:\s*\*/);
    expect(robots).toMatch(/^Disallow:\s*\/\s*$/m);
    expect(robots).toMatch(/^Allow:\s*\/\$\s*$/m);
    expect(robots).toMatch(/^Allow:\s*\/privacy\s*$/m);
    expect(robots).toMatch(/^Allow:\s*\/terms\s*$/m);
  });

  test('explicitly names the known authenticated routes as disallowed', () => {
    for (const route of ['/reader', '/account', '/signin', '/forgot-password', '/reset-password', '/verify-2fa']) {
      const escaped = route.replace(/\//g, '\\/');
      expect(robots).toMatch(new RegExp(`^Disallow:\\s*${escaped}\\s*$`, 'm'));
    }
  });

  test('points at the sitemap on the real production domain', () => {
    expect(robots).toMatch(/^Sitemap:\s*https:\/\/fellowscript\.com\/sitemap\.xml\s*$/m);
  });

  test('never names /admin -- naming it would itself be the disclosure this file must avoid', () => {
    expect(robots.toLowerCase()).not.toMatch(/admin/);
  });
});

describe('sitemap.xml', () => {
  test('lists only the genuinely public, independently crawlable routes, on the real production domain', () => {
    const locs = Array.from(sitemap.matchAll(/<loc>(.*?)<\/loc>/g)).map((m) => m[1]);

    expect(locs).toContain('https://fellowscript.com/');
    for (const loc of locs) {
      expect(loc.startsWith('https://fellowscript.com')).toBe(true);
    }
  });

  // Task 20260918-fix-google-indexing-audit (Issue B / option B1): under
  // HashRouter, everything after "#" is a client-side fragment the server
  // never sees, so /#/privacy and /#/terms were never independently
  // crawlable -- they were dead sitemap entries with no real static-route
  // equivalent to repoint at, so they were removed rather than kept as a
  // best-effort declaration.
  test('no longer lists dead /#/privacy or /#/terms fragment URLs (never crawlable under HashRouter)', () => {
    const locs = Array.from(sitemap.matchAll(/<loc>(.*?)<\/loc>/g)).map((m) => m[1]);

    expect(locs.some((l) => l.includes('/#/'))).toBe(false);
    expect(locs.some((l) => l.endsWith('/privacy'))).toBe(false);
    expect(locs.some((l) => l.endsWith('/terms'))).toBe(false);
  });

  test('never names /admin', () => {
    expect(sitemap.toLowerCase()).not.toMatch(/admin/);
  });

  test('is well-formed enough to parse: urlset root, and every <url> tag closes', () => {
    expect(sitemap).toMatch(/<urlset[^>]*>/);
    const urlOpens = (sitemap.match(/<url>/g) || []).length;
    const urlCloses = (sitemap.match(/<\/url>/g) || []).length;
    expect(urlOpens).toBe(urlCloses);
    expect(urlOpens).toBeGreaterThanOrEqual(1);
  });

  // Testing gate (task 20260918-fix-google-indexing-audit): the tag-balance
  // check above doesn't catch a genuinely malformed XML comment. XML forbids
  // "--" anywhere inside a comment body (only "-->" may end it) -- an
  // em-dash-style "--" separator in the header comment's prose (as opposed
  // to a real em dash "—") breaks the file for any strict XML parser,
  // including Google's sitemap fetcher, even though this file's own
  // structural regex checks above all still pass. Use the same DOMParser a
  // browser/crawler would use, not another regex, so this actually catches
  // the failure mode a hand-rolled string check would miss.
  test('the header comment contains no bare "--" (invalid inside an XML comment) and the file parses without a parsererror', () => {
    const doc = new DOMParser().parseFromString(sitemap, 'application/xml');
    expect(doc.querySelector('parsererror')).toBeNull();
  });
});

describe('deploy.sh', () => {
  test('ships dist/robots.txt and dist/sitemap.xml to production (the deploy gap architecture flagged)', () => {
    const deploySh = fs.readFileSync(path.join(REPO_ROOT, 'deploy.sh'), 'utf8');
    expect(deploySh).toMatch(/robots\.txt/);
    expect(deploySh).toMatch(/sitemap\.xml/);
  });
});
