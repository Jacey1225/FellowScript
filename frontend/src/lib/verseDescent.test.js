import { describe, test, expect } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  VERSE_D, VERSE_X, verseStep, verseProgress, verseState,
} from './verseDescent.js';
import { COMMUNITY_VERSES } from './communityVerses.js';
import { VERSE_START_P, VERSE_SPAN_P, P_END } from './adamHands/driver.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const bible = JSON.parse(fs.readFileSync(path.resolve(here, '../../../data/bible.json'), 'utf8'));

// bible.json chapters are one string: "10:1 text2text3text..." (verse numbers inline).
function webVerses(book, chapter, from, to) {
  const s = bible[book].find((c) => c.startsWith(`${chapter}:1 `));
  if (!s) throw new Error(`no ${book} ${chapter}`);
  const idx = { 1: `${chapter}:1 `.length };
  let cur = 1;
  for (;;) {
    const m = new RegExp(`(?<=[^\\d])${cur + 1}(?=[^\\d\\s])`).exec(s.slice(idx[cur] + 1));
    if (!m) break;
    cur += 1; idx[cur] = idx[cur - 1] + 1 + m.index;
  }
  const out = [];
  for (let v = from; v <= to; v++) {
    const start = idx[v] + (v === 1 ? 0 : String(v).length);
    out.push(s.slice(start, idx[v + 1] ?? s.length).trim());
  }
  return out.join(' ');
}

describe('community verses are exact World English Bible text', () => {
  const cases = [
    ['Hebrews 10:24-25', 'Hebrews', 10, 24, 25],
    ['Proverbs 27:17', 'Proverbs', 27, 17, 17],
    ['Ecclesiastes 4:9-12', 'Ecclesiastes', 4, 9, 12],
    ['Acts 2:44-45', 'Acts', 2, 44, 45],
    ['1 Thessalonians 5:11', '1 Thessalonians', 5, 11, 11],
  ];
  test('list matches the planned references in order', () => {
    expect(COMMUNITY_VERSES.map((v) => v.ref)).toEqual(cases.map((c) => c[0]));
    expect(COMMUNITY_VERSES.length).toBeGreaterThanOrEqual(3);
  });
  test.each(cases)('%s matches data/bible.json', (ref, book, ch, a, z) => {
    const v = COMMUNITY_VERSES.find((x) => x.ref === ref);
    expect(v.text).toBe(webVerses(book, ch, a, z));
    expect(v.text.split(/\s+/).length).toBeLessThanOrEqual(80);
  });
});

describe('verse descent maths', () => {
  const N = 5;
  test('step and progress', () => {
    expect(verseStep(5)).toBeCloseTo(0.15, 9);
    expect(VERSE_D).toBe(0.4);
    expect(verseProgress(VERSE_START_P, false)).toBe(0);
    expect(verseProgress(VERSE_START_P - 1, true)).toBe(0);
    expect(verseProgress(P_END.desktop, false)).toBeCloseTo(1, 9);
    expect(verseProgress(P_END.mobile, true)).toBeCloseTo(1, 9);
    expect(verseProgress(99, false)).toBe(1);
  });
  test('all widgets off-screen before and after the phase', () => {
    for (let i = 0; i < N; i++) {
      for (const [p, m] of [[VERSE_START_P, false], [1.2, false], [P_END.desktop, false], [P_END.mobile, true]]) {
        const s = verseState(i, N, p, m);
        expect(s.visible).toBe(false); expect(s.opacity).toBe(0);
      }
    }
    expect(verseState(0, N, P_END.desktop, false).yVh).toBeCloseTo(120, 6);
    expect(verseState(4, N, VERSE_START_P, false).yVh).toBeCloseTo(-20, 6);
  });
  test('widgets descend in order, top to bottom, centre y monotonic in p', () => {
    for (let i = 0; i < N; i++) {
      let prev = -Infinity;
      for (let p = VERSE_START_P; p <= P_END.desktop; p += 0.01) {
        const y = verseState(i, N, p, false).yVh; expect(y).toBeGreaterThanOrEqual(prev); prev = y;
      }
    }
    // widget i reaches mid-stage before widget i+1
    const mid = (i) => { for (let p = VERSE_START_P; p <= P_END.desktop; p += 0.001) if (verseState(i, N, p, false).yVh >= 50) return p; return Infinity; };
    for (let i = 0; i < N - 1; i++) expect(mid(i)).toBeLessThan(mid(i + 1));
  });
  test('spacing: consecutive centres 52.5vh apart, so cards of up to 44vh never overlap', () => {
    for (let p = VERSE_START_P; p <= P_END.desktop; p += 0.01) {
      for (let i = 0; i < N - 1; i++) {
        const a = verseState(i, N, p, false); const b = verseState(i + 1, N, p, false);
        if (a.visible && b.visible) expect(a.yVh - b.yVh).toBeGreaterThanOrEqual(44 - 1e-9);
      }
    }
    const a = verseState(0, N, 1.7, false); const b = verseState(1, N, 1.7, false);
    expect(a.yVh - b.yVh).toBeCloseTo(52.5, 6);
  });
  test('opacity fades in and out; x positions come from the table', () => {
    const s = verseState(0, N, VERSE_START_P + 0.5 * VERSE_SPAN_P.desktop * 0.4, false);
    expect(s.opacity).toBeGreaterThan(0.99);
    expect(verseState(1, N, 2.0, false).xPct).toBe(VERSE_X.desktop[1]);
    expect(verseState(1, N, 2.0, true).xPct).toBe(VERSE_X.mobile[1]);
  });
  test('Family headline is gone before the first widget reaches mid-stage', () => {
    // first widget centre < 15vh at p = FAMILY_HIDE end 1.46? (design: y < 15vh until then)
    expect(verseState(0, N, 1.46, false).yVh).toBeLessThan(15);
  });
});
