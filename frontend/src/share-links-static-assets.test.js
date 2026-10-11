// @vitest-environment jsdom
// Task 20261011-ios-share-notes-highlights: static landing pages for the
// friend-request (/u/<username>) and verse (/v/<book>/<chapter>/<verse>) share
// links, their AASA components and the prepared (not applied) nginx snippet.
import { describe, test, expect, beforeEach } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(__dirname, '../..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

describe('apple-app-site-association', () => {
  const j = JSON.parse(read('frontend/public/.well-known/apple-app-site-association'));
  test('adds /u/*, /v/* and /g/*; /join/* and the appID are unchanged', () => {
    const d = j.applinks.details[0];
    expect(j.applinks.details).toHaveLength(1);
    expect(d.appIDs).toEqual(['886XPLVC69.com.fellowscript.app']);
    expect(d.components.map((c) => c['/'])).toEqual(['/join/*', '/u/*', '/v/*', '/g/*']);
  });
});

describe('nginx snippet', () => {
  const n = read('ops/nginx/invite-links.conf');
  test('serves exactly one fixed file per prefix, noindex + no-referrer, no proxy/redirect', () => {
    for (const p of ['u', 'v', 'g']) {
      const re = new RegExp(`location \\^~ /${p}/ \\{([^}]*)\\}`);
      const block = n.match(re)[1];
      expect(block).toContain(`try_files /${p}/index.html =404;`);
      expect(block).toContain('Referrer-Policy "no-referrer"');
      expect(block).toContain('X-Robots-Tag "noindex, nofollow"');
      expect(block).toContain('Cache-Control "no-store"');
      expect(block).not.toMatch(/proxy_pass|return\s+30|rewrite\s/);
    }
  });
  test('existing /join/ location is untouched', () => {
    expect(n).toMatch(/location \^~ \/join\/ \{[^}]*try_files \/join\/index\.html =404;/);
  });
  test('deploy.sh ships the pages narrowly and never touches nginx', () => {
    const d = read('deploy.sh');
    const added = d.slice(d.indexOf('task 20261011-ios-share-notes-highlights'));
    expect(added).toContain('frontend/dist/u/index.html');
    expect(added).toContain('frontend/dist/v/index.html');
    expect(added).toContain('frontend/dist/g/index.html');
    expect(added).not.toMatch(/nginx (-|reload)|systemctl|rsync|--delete|rm -rf|sudo/);
  });
});

function loader(file) {
  const html = read(file);
  const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
  const run = (pathname) => {
    document.documentElement.innerHTML = html.replace(/<script>[\s\S]*?<\/script>/, '');
    window.history.pushState({}, '', pathname);
    new Function(script)(); // eslint-disable-line no-new-func
    return (id) => document.getElementById(id);
  };
  return { html, script, run };
}

describe.each([['u', 'frontend/public/u/index.html'], ['v', 'frontend/public/v/index.html'], ['g', 'frontend/public/g/index.html']])('page /%s/ hardening', (_k, file) => {
  const { html, script } = loader(file);
  test('noindex, no-referrer, no external scripts, no DOM/location sinks', () => {
    expect(html).toMatch(/name="robots" content="noindex, nofollow"/);
    expect(html).toMatch(/name="referrer" content="no-referrer"/);
    expect(html).not.toMatch(/<script[^>]*\ssrc=/i);
    expect(html).not.toMatch(/http-equiv="refresh"/i);
    expect(script).not.toMatch(/innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(|location\s*(\.href|\.assign|\.replace)?\s*=[^=]/);
    expect(script).not.toMatch(/location\.(search|hash|href)|document\.URL/);
  });
  test('app store link is the fixed apps.apple.com URL', () => {
    expect(html).toMatch(/id="appstore" class="pill" href="https:\/\/apps\.apple\.com\//);
  });
});

describe('/u/<username>', () => {
  const { run } = loader('frontend/public/u/index.html');
  beforeEach(() => { document.documentElement.innerHTML = ''; });
  test.each(['/u/alice', '/u/Alice_B-1.x/', `/u/${'a'.repeat(32)}`])('valid %s shows app prompt, username never in DOM', (p) => {
    const $ = run(p);
    expect($('valid').hidden).toBe(false);
    expect($('appstore').hidden).toBe(false);
    expect($('invalid').hidden).toBe(true);
    expect(document.body.textContent).not.toContain(p.split('/')[2]);
  });
  test.each([
    ['empty', '/u/'], ['too long', `/u/${'a'.repeat(33)}`], ['html chars', '/u/%3Cscript%3E'],
    ['raw lt', '/u/a<b'], ['extra segment', '/u/alice/extra'], ['traversal', '/u/..%2Fevil'],
    ['space', '/u/a%20b'], ['js scheme', '/u/javascript:alert(1)'],
  ])('invalid (%s)', (_n, p) => {
    const $ = run(p);
    expect($('invalid').hidden).toBe(false);
    expect($('valid').hidden).toBe(true);
    expect($('appstore').hidden).toBe(true);
    expect($('home').getAttribute('href')).toBe('/');
  });
});

describe('/g/<public_id>', () => {
  const { run, html, script } = loader('frontend/public/g/index.html');
  beforeEach(() => { document.documentElement.innerHTML = ''; });
  test('no network calls and no id rendering', () => {
    expect(script).not.toMatch(/fetch\(|XMLHttpRequest|sendBeacon|WebSocket|textContent|innerText/);
    expect(html).not.toMatch(/fetch\(|innerHTML|gtag|googletagmanager/);
    expect(script.match(/location\./g)).toHaveLength(1);
    expect(script).toContain('window.location.pathname);');
  });
  test.each(['/g/aB3dE6gH9k', '/g/0123456789/', '/g/ABCDEFGHIJ'])('valid %s; id never in DOM', (p) => {
    const $ = run(p);
    expect($('valid').hidden).toBe(false);
    expect($('appstore').hidden).toBe(false);
    expect($('invalid').hidden).toBe(true);
    expect(document.body.textContent).not.toContain(p.split('/')[2]);
  });
  test.each([
    ['empty', '/g/'], ['9 chars', '/g/abcdefghi'], ['11 chars', '/g/abcdefghijk'], ['hyphen', '/g/abcdefghi-'],
    ['encoded', '/g/abcdefghi%41'], ['html', '/g/%3Cscript%3E'], ['unicode digit', '/g/abcdefghi\u0663'],
    ['extra segment', '/g/abcdefghij/x'], ['double slash', '/g//abcdefghij'], ['newline', '/g/abcdefghi%0A'],
  ])('invalid (%s)', (_n, p) => {
    const $ = run(p);
    expect($('invalid').hidden).toBe(false);
    expect($('valid').hidden).toBe(true);
    expect($('appstore').hidden).toBe(true);
  });
});

describe('/v/<book>/<chapter>/<verse>', () => {
  const { run, script } = loader('frontend/public/v/index.html');
  beforeEach(() => { document.documentElement.innerHTML = ''; });
  test('table has all 66 canonical slugs', () => {
    const slugs = [...script.matchAll(/^\s+"([a-z0-9-]+)": "/gm)].map((m) => m[1]);
    expect(slugs).toHaveLength(66);
    expect(new Set(slugs).size).toBe(66);
    expect(slugs).toContain('song-of-solomon');
    expect(slugs).toContain('1-samuel');
  });
  test.each([
    ['/v/john/3/16', 'John 3:16'], ['/v/1-samuel/17/45/', '1 Samuel 17:45'], ['/v/song-of-solomon/2/1', 'Song of Solomon 2:1'],
  ])('valid %s renders the table name via textContent', (p, ref) => {
    const $ = run(p);
    expect($('valid').hidden).toBe(false);
    expect($('ref').textContent).toBe(ref);
    expect($('appstore').hidden).toBe(false);
  });
  test.each([
    ['unknown book', '/v/notabook/1/1'], ['proto key', '/v/constructor/1/1'], ['proto dunder', '/v/__proto__/1/1'],
    ['zero chapter', '/v/john/0/1'], ['zero verse', '/v/john/1/0'], ['four digits', '/v/john/1000/1'],
    ['non numeric', '/v/john/a/1'], ['missing verse', '/v/john/3'], ['extra segment', '/v/john/3/16/x'],
    ['uppercase', '/v/John/3/16'], ['encoded', '/v/john%2F/3/16'],
  ])('invalid (%s): shows invalid state only', (_n, p) => {
    const $ = run(p);
    expect($('invalid').hidden).toBe(false);
    expect($('valid').hidden).toBe(true);
    expect($('ref').textContent).toBe('');
    expect($('appstore').hidden).toBe(true);
  });
});

describe('vite copies the pages into dist verbatim', () => {
  test.each(['u', 'v', 'g'])('%s/index.html', (p) => {
    const dist = path.join(root, `frontend/dist/${p}/index.html`);
    if (!fs.existsSync(dist)) return; // dist not built in this checkout
    expect(fs.readFileSync(dist, 'utf8')).toBe(read(`frontend/public/${p}/index.html`));
  });
});
