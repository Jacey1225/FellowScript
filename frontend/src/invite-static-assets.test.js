// @vitest-environment jsdom
// Task 20260929-group-invite-links testing: the static landing page and the
// apple-app-site-association file that ship from frontend/public, plus the
// nginx snippet and deploy.sh lines that serve them.
import { describe, test, expect, beforeEach } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(__dirname, '../..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const TOKEN = 'A'.repeat(43);

describe('apple-app-site-association', () => {
  const raw = read('frontend/public/.well-known/apple-app-site-association');
  test('is valid JSON with the right appID and only /join/*', () => {
    const j = JSON.parse(raw);
    expect(Object.keys(j)).toEqual(['applinks']);
    expect(j.applinks.details).toHaveLength(1);
    const d = j.applinks.details[0];
    expect(d.appIDs).toEqual(['886XPLVC69.com.fellowscript.app']);
    expect(d.components.map((c) => c['/'])).toEqual(['/join/*']);
  });
  test('file has no extension and the appID matches the app bundle id', () => {
    expect(fs.existsSync(path.join(root, 'frontend/public/.well-known/apple-app-site-association.json'))).toBe(false);
    const pbx = read('FellowScript/FellowScript.xcodeproj/project.pbxproj');
    expect(pbx).toContain('PRODUCT_BUNDLE_IDENTIFIER = com.fellowscript.app;');
    expect(pbx).toContain('DEVELOPMENT_TEAM = 886XPLVC69;');
  });
});

describe('entitlements + nginx + deploy', () => {
  test('iOS entitlement declares applinks:fellowscript.com', () => {
    const e = read('FellowScript/FellowScript/FellowScript.entitlements');
    expect(e).toContain('com.apple.developer.associated-domains');
    expect(e).toContain('<string>applinks:fellowscript.com</string>');
  });
  test('nginx serves AASA as exact-match application/json with no redirect', () => {
    const n = read('ops/nginx/invite-links.conf');
    expect(n).toMatch(/location = \/\.well-known\/apple-app-site-association \{[^}]*default_type application\/json;/);
    expect(n).not.toMatch(/return\s+30[1278]|rewrite\s/);
    expect(n).toMatch(/location \^~ \/join\/ \{[^}]*try_files \/join\/index\.html =404;/);
  });
  test('deploy.sh only gained narrow scp lines and never touches nginx', () => {
    const d = read('deploy.sh');
    expect(d).toContain('frontend/dist/join/index.html');
    expect(d).toContain('frontend/dist/.well-known/apple-app-site-association');
    // Bounded at the next task's marker (20260930-downloads-page-indexable
    // appends its own narrow mkdir + scp below; covered in
    // seo/downloadSeo.build.test.js and robots-sitemap.test.js).
    const start = d.indexOf('task 20260929-group-invite-links');
    const next = d.indexOf('task 20260930-downloads-page-indexable');
    const added = d.slice(start, next === -1 ? undefined : next);
    expect(added).not.toMatch(/nginx (-|reload)|systemctl|rsync|--delete|rm -rf|sudo/);
    expect((added.match(/^ssh /gm) || [])).toHaveLength(1); // only the mkdir -p
    expect(added).toContain('mkdir -p /var/www/html/join /var/www/html/.well-known');
  });
});

describe('static landing page /join/<token>', () => {
  const html = read('frontend/public/join/index.html');
  const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

  function run(pathname) {
    document.documentElement.innerHTML = html.replace(/<script>[\s\S]*?<\/script>/, '');
    window.history.pushState({}, '', pathname);
    new Function(script)(); // eslint-disable-line no-new-func
    const $ = (id) => document.getElementById(id);
    return { $ };
  }
  beforeEach(() => { document.documentElement.innerHTML = ''; });

  test('page is noindex, no-referrer, and has no meta refresh / location writes', () => {
    expect(html).toMatch(/name="robots" content="noindex, nofollow"/);
    expect(html).toMatch(/name="referrer" content="no-referrer"/);
    expect(html).not.toMatch(/http-equiv="refresh"/i);
    expect(script).not.toMatch(/location\s*(\.href|\.assign|\.replace)?\s*=[^=]/);
    expect(script).not.toMatch(/innerHTML|document\.write|eval\(/);
  });

  test('valid token: continue link is exactly the fixed same-origin /#/join/<token>', () => {
    const { $ } = run(`/join/${TOKEN}`);
    expect($('continue').getAttribute('href')).toBe(`/#/join/${TOKEN}`);
    expect($('continue').hidden).toBe(false);
    expect($('appstore').hidden).toBe(false);
    expect($('appstore').getAttribute('href')).toMatch(/^https:\/\/apps\.apple\.com\//);
    expect($('invalid').hidden).toBe(true);
  });

  test.each([
    ['too short', '/join/abc'],
    ['bad chars', `/join/${'A'.repeat(42)}<`],
    ['extra segment', `/join/${TOKEN}/extra`],
    ['bare join', '/join/'],
    ['url-encoded traversal', '/join/..%2F..%2Fevil.com'],
    ['scheme-relative token', '/join///evil.com'],
    ['javascript payload', '/join/javascript:alert(1)'],
  ])('invalid (%s): shows invalid state and a home link, never a token link', (_n, p) => {
    const { $ } = run(p);
    expect($('invalid').hidden).toBe(false);
    expect($('valid').hidden).toBe(true);
    expect($('continue').hidden).toBe(true);
    expect($('continue').getAttribute('href')).toBe('/');
    expect($('home').getAttribute('href')).toBe('/');
  });

  test('query string and hash cannot influence the destination', () => {
    const { $ } = run(`/join/${TOKEN}?next=https://evil.com#https://evil.com`);
    expect($('continue').getAttribute('href')).toBe(`/#/join/${TOKEN}`);
  });

  test('vite copies both static files into dist verbatim', () => {
    const dist = path.join(root, 'frontend/dist');
    if (!fs.existsSync(path.join(dist, 'join/index.html'))) return; // dist not built in this checkout
    expect(fs.readFileSync(path.join(dist, 'join/index.html'), 'utf8')).toBe(html);
    expect(fs.readFileSync(path.join(dist, '.well-known/apple-app-site-association'), 'utf8'))
      .toBe(read('frontend/public/.well-known/apple-app-site-association'));
  });
});
