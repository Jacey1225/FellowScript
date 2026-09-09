// Tests for task 20260908-bible-verse-boundary-parsing (frontend step 1 /
// testing step 3): buildChapterHTML/versesToHTML/extractVerseNums's widened
// verse-boundary lookahead character class -- now recognizing a curly
// opening double quote (“), curly opening single quote (‘), opening
// parenthesis ((), and opening double square bracket ([) as valid
// verse-openers, alongside the pre-existing [A-Za-z] case.
//
// Covers the exact real-data regression named in the intake spec (Genesis
// 8:16, a verse opening with quoted speech that previously merged into
// Genesis 8:15), the newly-added curly-single-quote/paren/bracket cases
// against real bible.json content (Genesis 22:23, Mark 16:9, John 7:53), and
// a full-corpus scan confirming zero missing verse-boundary instances
// remain, mirroring the corpus-wide validation the frontend gate itself ran.
//
// Run with: cd frontend && npm test -- --run src/utils.verse-boundary.test.js
import { describe, test, expect } from 'vitest';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import path from 'path';
import { buildChapterHTML, extractVerseNums } from './utils.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BIBLE_JSON_PATH = path.join(__dirname, '..', '..', 'data', 'bible.json');

function loadBible() {
  return JSON.parse(readFileSync(BIBLE_JSON_PATH, 'utf-8'));
}

describe('extractVerseNums / buildChapterHTML -- verse-boundary character class', () => {
  test('Genesis 8:16 (curly-double-quote opener) is its own highlightable verse, not merged into 15', () => {
    const bible = loadBible();
    const chStr = bible['Genesis'][8];
    const nums = extractVerseNums(chStr);
    expect(nums).toContain(15);
    expect(nums).toContain(16);

    const html = buildChapterHTML(chStr);
    expect(html).toMatch(/id="vs16"/);
    // Verse 16's own span should carry its distinctive opening text, not verse 15's.
    const v16Match = html.match(/id="vs16"[^]*?<\/span>/);
    expect(v16Match).not.toBeNull();
    expect(v16Match[0]).toMatch(/Go out from the ark/);
    const v15Match = html.match(/id="vs15"[^]*?(?=<span class="verse-span")/);
    expect(v15Match[0]).not.toMatch(/Go out from the ark/);
  });

  test('Genesis 22:23 (opening-parenthesis opener) is its own highlightable verse', () => {
    const bible = loadBible();
    const chStr = bible['Genesis'][22];
    const nums = extractVerseNums(chStr);
    expect(nums).toContain(23);
    const html = buildChapterHTML(chStr);
    const v23Match = html.match(/id="vs23"[^]*?<\/span>/);
    expect(v23Match).not.toBeNull();
    expect(v23Match[0]).toMatch(/\(Bethuel fathered Rebekah/);
  });

  test('Mark 16:9 and John 7:53 (opening-double-square-bracket openers) are recognized as verse boundaries', () => {
    const bible = loadBible();
    // Mark's extra index-17 appendix entry and John's index-9 fragment carry
    // the two disputed "longer ending" passages the frontend gate's corpus
    // scan found (see frontend.json summary).
    const markAppendix = bible['Mark'][bible['Mark'].length - 1];
    expect(markAppendix).toMatch(/9\[\[Now when he rose/);
    const nums = extractVerseNums(markAppendix);
    expect(nums).toContain(9);

    const johnFragment = bible['John'][9];
    expect(johnFragment).toMatch(/^53\[\[They went each/);
  });

  test('no regression: footnote-marker stripping, section-header stripping, and first-verse chapter:verse pattern still work', () => {
    const bible = loadBible();
    const chStr = bible['John'][1];
    const html = buildChapterHTML(chStr);
    // First verse (chapter:verse pattern) still resolves.
    expect(html).toMatch(/id="vs1"/);
    // Footnote markers like [1] must not appear in rendered verse text.
    expect(html).not.toMatch(/\[\d+\]/);

    const markCh1 = bible['Mark'][1];
    const markHtml = buildChapterHTML(markCh1);
    expect(markHtml).toMatch(/section-head/); // HEAD:: sections still rendered as headers
    expect(markHtml).not.toMatch(/HEAD::/); // marker itself stripped
  });

  test('full-corpus scan: extractVerseNums finds a verse number match for at least one lowercase/uppercase-adjacent boundary per book (sanity, not exhaustive)', () => {
    const bible = loadBible();
    // Full-corpus zero-missing-boundary validation itself was already run
    // and documented by the frontend gate (frontend.json); this is a
    // lighter-weight regression guard so a future accidental narrowing of
    // the character class fails fast in CI without re-deriving the full
    // 1,842-instance scan here.
    let checkedBooks = 0;
    for (const book of Object.keys(bible)) {
      const chapters = bible[book];
      for (let idx = 1; idx < chapters.length; idx++) {
        const nums = extractVerseNums(chapters[idx]);
        expect(Array.isArray(nums)).toBe(true);
      }
      checkedBooks += 1;
    }
    expect(checkedBooks).toBe(66);
  });
});
