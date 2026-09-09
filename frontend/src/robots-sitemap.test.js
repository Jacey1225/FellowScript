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
  test('lists only the genuinely public marketing routes, on the real production domain', () => {
    const locs = Array.from(sitemap.matchAll(/<loc>(.*?)<\/loc>/g)).map((m) => m[1]);

    expect(locs).toContain('https://fellowscript.com/');
    expect(locs.some((l) => l.endsWith('/privacy'))).toBe(true);
    expect(locs.some((l) => l.endsWith('/terms'))).toBe(true);
    for (const loc of locs) {
      expect(loc.startsWith('https://fellowscript.com')).toBe(true);
    }
  });

  test('never names /admin', () => {
    expect(sitemap.toLowerCase()).not.toMatch(/admin/);
  });

  test('is well-formed enough to parse: urlset root, and every <url> tag closes', () => {
    expect(sitemap).toMatch(/<urlset[^>]*>/);
    const urlOpens = (sitemap.match(/<url>/g) || []).length;
    const urlCloses = (sitemap.match(/<\/url>/g) || []).length;
    expect(urlOpens).toBe(urlCloses);
    expect(urlOpens).toBeGreaterThanOrEqual(3);
  });
});

describe('deploy.sh', () => {
  test('ships dist/robots.txt and dist/sitemap.xml to production (the deploy gap architecture flagged)', () => {
    const deploySh = fs.readFileSync(path.join(REPO_ROOT, 'deploy.sh'), 'utf8');
    expect(deploySh).toMatch(/robots\.txt/);
    expect(deploySh).toMatch(/sitemap\.xml/);
  });
});
