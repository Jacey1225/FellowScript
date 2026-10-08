// @vitest-environment node
//
// Task 20260930-stable-favicons-google. Builds the site and checks that stable,
// unhashed favicon files exist at the dist root and that every crawled page head
// declares them (Google needs a stable, square, multiple-of-48 icon URL).
//
// Run with: cd frontend && npm test -- --run src/seo/favicon.build.test.js
import path from 'path';
import fs from 'fs';
import { execSync } from 'child_process';
import { fileURLToPath } from 'url';
import { describe, test, expect, beforeAll } from 'vitest';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '../..');
const DIST = path.join(ROOT, 'dist');
const PUB = path.join(ROOT, 'public');
const FILES = ['favicon.ico', 'favicon.svg', 'favicon-48x48.png', 'favicon-192x192.png', 'apple-touch-icon.png'];

const pngSize = (buf) => {
  expect(buf.subarray(0, 8).toString('hex')).toBe('89504e470d0a1a0a');
  return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20) };
};

const pages = {};

beforeAll(() => {
  execSync('npm run build', { cwd: ROOT, stdio: 'pipe' });
  pages['dist/index.html'] = fs.readFileSync(path.join(DIST, 'index.html'), 'utf8');
  pages['dist/download/index.html'] = fs.readFileSync(path.join(DIST, 'download/index.html'), 'utf8');
  pages['dist/explore/index.html'] = fs.readFileSync(path.join(DIST, 'explore/index.html'), 'utf8');
}, 240000);

describe('stable favicon files', () => {
  test.each(FILES)('%s is in dist root and byte-identical to public/', (f) => {
    const d = fs.readFileSync(path.join(DIST, f));
    expect(d.length).toBeGreaterThan(0);
    expect(d.equals(fs.readFileSync(path.join(PUB, f)))).toBe(true);
  });

  test.each([['favicon-48x48.png', 48], ['favicon-192x192.png', 192], ['apple-touch-icon.png', 180]])(
    '%s is square %ipx',
    (f, n) => {
      const { w, h } = pngSize(fs.readFileSync(path.join(DIST, f)));
      expect(w).toBe(n);
      expect(h).toBe(n);
    },
  );

  test('Google-facing PNG sizes are multiples of 48', () => {
    expect(48 % 48).toBe(0);
    expect(192 % 48).toBe(0);
  });

  test('favicon.ico is a valid ICO containing a 48x48 image', () => {
    const b = fs.readFileSync(path.join(DIST, 'favicon.ico'));
    expect(b.readUInt16LE(0)).toBe(0);
    expect(b.readUInt16LE(2)).toBe(1);
    const count = b.readUInt16LE(4);
    expect(count).toBeGreaterThanOrEqual(1);
    const sizes = [];
    for (let i = 0; i < count; i++) sizes.push(b[6 + i * 16] || 256);
    expect(sizes).toContain(48);
  });

  test('favicon.svg is a real SVG', () => {
    expect(fs.readFileSync(path.join(DIST, 'favicon.svg'), 'utf8')).toMatch(/<svg[\s>]/);
  });
});

describe.each(['dist/index.html', 'dist/download/index.html', 'dist/explore/index.html'])('%s head icons', (page) => {
  test('declares stable root-relative icon links', () => {
    const html = pages[page];
    expect(html).toMatch(/<link[^>]+rel="icon"[^>]+href="\/favicon\.ico"/);
    expect(html).toMatch(/<link[^>]+rel="icon"[^>]+href="\/favicon\.svg"/);
    expect(html).toMatch(/<link[^>]+href="\/favicon-48x48\.png"/);
    expect(html).toMatch(/<link[^>]+href="\/favicon-192x192\.png"/);
    expect(html).toMatch(/<link[^>]+rel="apple-touch-icon"[^>]+href="\/apple-touch-icon\.png"/);
  });

  test('has no hashed or tab_logo icon link', () => {
    const icons = pages[page].match(/<link[^>]+rel="(?:shortcut )?icon"[^>]*>/g) || [];
    expect(icons.length).toBeGreaterThanOrEqual(4);
    for (const l of icons) {
      expect(l).not.toMatch(/tab_logo/);
      expect(l).not.toMatch(/\/assets\//);
    }
  });
});
