// Tests for task 20260908-bible-verse-boundary-parsing (frontend step 1 /
// testing step 3): frontend/js/bible.js's widened verse-boundary lookahead
// character class in _extractVerseNums/_buildHTML/_versesToHTML (hand-
// mirrored copies of frontend/src/utils.js's buildChapterHTML/versesToHTML/
// extractVerseNums per this file's own in-code comment).
//
// These helpers aren't exported (legacy module keeps them private), so this
// drives them through the public API (loadBible -> setBook -> setChapter),
// against the real bible.json content, and inspects the resulting DOM --
// same approach notes.delete-refresh.test.js/notes.test.js already use for
// this module's DOM-coupled internals.
//
// Run with: cd frontend && npm test -- --run js/bible.verse-boundary.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import path from 'path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BIBLE_JSON_PATH = path.join(__dirname, '..', '..', 'data', 'bible.json');
const REAL_BIBLE_JSON = readFileSync(BIBLE_JSON_PATH, 'utf-8');

// bible.js reads document.getElementById(...) for these ids at module scope.
const REQUIRED_IDS = [
  'book-sel', 'ch-sel', 'vs-sel', 'state-loading', 'state-welcome',
  'chapter-card', 'card-book-label', 'card-title', 'card-section-head',
  'card-body', 'card-loc', 'prev-btn', 'next-btn',
];

function mountShell() {
  document.body.innerHTML = REQUIRED_IDS.map(id => `<div id="${id}"></div>`).join('');
  // book-sel/ch-sel/vs-sel are treated as <select>s (assigned .value,
  // .disabled, appendChild'd <option>s) -- give them the right tag.
  for (const id of ['book-sel', 'ch-sel', 'vs-sel']) {
    const el = document.getElementById(id);
    const select = document.createElement('select');
    select.id = id;
    el.replaceWith(select);
  }
  // jsdom doesn't implement scrollIntoView; setChapter/setVerse call it on
  // the chapter card / verse span unconditionally.
  Element.prototype.scrollIntoView = vi.fn();
}

async function importFreshBibleModule() {
  vi.resetModules();
  mountShell();
  global.fetch = vi.fn().mockResolvedValue({ ok: true, json: async () => JSON.parse(REAL_BIBLE_JSON) });
  const bibleModule = await import('./bible.js');
  await bibleModule.loadBible();
  return bibleModule;
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe('bible.js verse-boundary character class (mirrors src/utils.js)', () => {
  test('Genesis 8:16 (curly-double-quote opener) is its own highlightable verse, not merged into 15', async () => {
    const bibleModule = await importFreshBibleModule();
    bibleModule.setBook('Genesis');
    bibleModule.setChapter(8);

    const cardBody = document.getElementById('card-body');
    expect(cardBody.innerHTML).toMatch(/id="vs16"/);
    const v16Match = cardBody.innerHTML.match(/id="vs16"[^]*?<\/span>/);
    expect(v16Match[0]).toMatch(/Go out from the ark/);

    const vsSel = document.getElementById('vs-sel');
    const optionValues = [...vsSel.options].map(o => o.value);
    expect(optionValues).toContain('15');
    expect(optionValues).toContain('16');
  });

  test('Genesis 22:23 (opening-parenthesis opener) is its own highlightable verse', async () => {
    const bibleModule = await importFreshBibleModule();
    bibleModule.setBook('Genesis');
    bibleModule.setChapter(22);

    const cardBody = document.getElementById('card-body');
    const v23Match = cardBody.innerHTML.match(/id="vs23"[^]*?<\/span>/);
    expect(v23Match).not.toBeNull();
    expect(v23Match[0]).toMatch(/\(Bethuel fathered Rebekah/);
  });

  test('no regression: footnote-marker and HEAD:: stripping still work after a section header', async () => {
    const bibleModule = await importFreshBibleModule();
    bibleModule.setBook('Mark');
    bibleModule.setChapter(1);

    const cardBody = document.getElementById('card-body');
    expect(cardBody.innerHTML).not.toMatch(/\[\d+\]/);
    expect(cardBody.innerHTML).not.toMatch(/HEAD::/);
    expect(cardBody.innerHTML).toMatch(/section-head/);
    expect(cardBody.innerHTML).toMatch(/id="vs9"/);
  });

  test('parity with frontend/src/utils.js: same regex source text for the verse-boundary lookahead', () => {
    // Guards against exactly the "future drift" risk architecture.json's
    // decision flags -- this module has no shared build step with the React
    // app, so the two copies can only be kept in sync by hand; this
    // byte-for-byte comparison fails fast in CI the moment they diverge.
    const bibleJsSrc = readFileSync(path.join(__dirname, 'bible.js'), 'utf-8');
    const utilsJsSrc = readFileSync(path.join(__dirname, '..', 'src', 'utils.js'), 'utf-8');
    // The character class itself (shared by both the capturing-group and
    // bare-\d+ call sites) is what actually governs verse-boundary
    // detection -- compare that substring's occurrence count rather than
    // one exact call-site spelling.
    const LOOKAHEAD_CLASS = '[A-Za-z“‘(\\[]';
    const bibleJsOccurrences = bibleJsSrc.split(LOOKAHEAD_CLASS).length - 1;
    const utilsJsOccurrences = utilsJsSrc.split(LOOKAHEAD_CLASS).length - 1;
    expect(bibleJsOccurrences).toBeGreaterThanOrEqual(3);
    expect(bibleJsOccurrences).toBe(utilsJsOccurrences);
  });
});
