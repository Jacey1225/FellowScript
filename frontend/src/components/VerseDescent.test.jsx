// Verse glass widgets: markup, accessibility, fallback, painting and the WCAG AA
// contrast bound (task 20261022-hands-scroll-grain-gradient, step 4).
// Run with: cd frontend && npx vitest run src/components/VerseDescent.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, cleanup } from '@testing-library/react';
import { renderToStaticMarkup, renderToString } from 'react-dom/server';
import { VerseDescent, VerseStack, VERSE_CSS, paintVerses } from './VerseDescent.jsx';
import AdamHands from './AdamHands.jsx';
import { COMMUNITY_VERSES } from '../lib/communityVerses.js';
import { VERSE_FILL, VERSE_INK, VERSE_REF_INK, VERSE_STACK_QUERY, VERSE_LABEL } from '../lib/verseDescent.js';
import { FIELD_WHITE, FIELD_END, FIELD_INK, FIELD_ZONE_MAX, FIELD_BLOBS, FIELD_UNDER, hexRgb, relLuminance } from '../lib/adamHands/field.js';
import { VERSE_START_P, VERSE_SPAN_P, P_END } from '../lib/adamHands/driver.js';

afterEach(() => { cleanup(); vi.restoreAllMocks(); });

const over = (a, bg) => VERSE_FILL.rgb.map((v, i) => v * a + bg[i] * (1 - a));
const lum = (c) => relLuminance(c);
const ratio = (fg, bg) => { const [x, y] = [lum(fg), lum(bg)].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05); };

describe('verse widget contrast (WCAG AA 4.5:1)', () => {
  const ink = hexRgb(VERSE_INK); const ref = hexRgb(VERSE_REF_INK);
  test('ink matches the field ink constant', () => { expect(VERSE_INK.toUpperCase()).toBe(FIELD_INK.toUpperCase()); });
  test('bounding case: the semi-opaque fill over warm white (never actually behind a verse), 7.0:1 / 5.9:1', () => {
    const bg = over(VERSE_FILL.a, hexRgb(FIELD_WHITE));
    expect(ratio(ink, bg)).toBeGreaterThanOrEqual(4.5);
    expect(ratio(ref, bg)).toBeGreaterThanOrEqual(4.5);
    expect(ratio(ink, bg)).toBeGreaterThanOrEqual(6.9);
    expect(ratio(ref, bg)).toBeGreaterThanOrEqual(5.8);
  });
  test('far glass alpha 0.86 and mobile alpha 0.93 also pass AA over every light field colour (with grain)', () => {
    for (const a of [VERSE_FILL.farA, 0.93]) {
      for (const hex of [FIELD_END, FIELD_WHITE, FIELD_ZONE_MAX, ...FIELD_BLOBS.map((b) => b.c)]) {
        const bg = over(a, hexRgb(hex)).map((v) => Math.min(255, v * 1.15));
        expect(ratio(ink, bg)).toBeGreaterThanOrEqual(4.5);
        expect(ratio(ref, bg)).toBeGreaterThanOrEqual(4.5);
      }
    }
  });
  test('over the lightest field colour, honey FIELD_END (the bottom pool): 8.5:1 ink, 7.1:1 ref', () => {
    const bg = over(VERSE_FILL.a, hexRgb(FIELD_END));
    expect(ratio(ink, bg)).toBeGreaterThanOrEqual(8.4);
    expect(ratio(ref, bg)).toBeGreaterThanOrEqual(7);
  });
  test('grain lightening the backdrop by up to 15% over every blob colour at full alpha (the real worst case; the field is never white behind a widget)', () => {
    for (const hex of [FIELD_END, FIELD_WHITE, FIELD_ZONE_MAX, ...FIELD_BLOBS.map((b) => b.c)]) {
      const bg = over(VERSE_FILL.a, hexRgb(hex)).map((v) => Math.min(255, v * 1.15));
      expect(ratio(ink, bg)).toBeGreaterThanOrEqual(4.5);
      expect(ratio(ref, bg)).toBeGreaterThanOrEqual(4.5);
    }
  });
  test('over the lightest field colours (honey, zone max, every blob colour at full alpha)', () => {
    const lights = [FIELD_END, FIELD_WHITE, FIELD_ZONE_MAX, ...FIELD_BLOBS.map((b) => b.c)];
    for (const hex of lights) {
      const bg = over(VERSE_FILL.a, hexRgb(hex));
      expect(ratio(ink, bg)).toBeGreaterThanOrEqual(4.5);
      expect(ratio(ref, bg)).toBeGreaterThanOrEqual(4.5);
    }
  });
  test('solid fallback (no backdrop-filter) is darker still and also passes over white', () => {
    const bg = over(VERSE_FILL.fallbackA, hexRgb(FIELD_WHITE));
    expect(ratio(ink, bg)).toBeGreaterThanOrEqual(4.5);
    expect(ratio(ref, bg)).toBeGreaterThanOrEqual(4.5);
    expect(VERSE_CSS).toMatch(/@supports not \(\(backdrop-filter: blur\(1px\)\) or \(-webkit-backdrop-filter: blur\(1px\)\)\) \{ \.verse \{ background: rgba\(34,19,6,0\.93\); \} \}/);
    expect(VERSE_CSS).toMatch(/backdrop-filter: blur\(22px\) saturate\(1\.15\)/);
    expect(VERSE_CSS).toMatch(/-webkit-backdrop-filter: blur\(22px\)/);
    expect(FIELD_UNDER).toContain('#EBC480');
    expect(VERSE_CSS).toMatch(/background: rgba\(34,19,6,var\(--va, 0\.72\)\)/);
    expect(VERSE_CSS).toMatch(/border: 1px solid rgba\(255,236,205,0\.22\)/);
  });
});

describe('markup and accessibility', () => {
  test('VerseStack: one figure/blockquote/figcaption per verse, labelled, in order', () => {
    const html = renderToStaticMarkup(<VerseStack />);
    expect(html).toContain(`aria-label="${VERSE_LABEL}"`);
    expect((html.match(/<figure /g) || []).length).toBe(COMMUNITY_VERSES.length);
    expect((html.match(/<blockquote /g) || []).length).toBe(COMMUNITY_VERSES.length);
    expect((html.match(/<figcaption /g) || []).length).toBe(COMMUNITY_VERSES.length);
    let at = -1;
    for (const v of COMMUNITY_VERSES) {
      const i = html.indexOf(v.ref); expect(i).toBeGreaterThan(at); at = i;
    }
    expect(html).not.toMatch(/aria-hidden/);
  });
  test('VerseDescent (pinned): visual layer aria-hidden, text exposed once via the sr-only list', () => {
    const { container } = render(<VerseDescent />);
    expect(container.querySelector('[data-adam="verses"]').getAttribute('aria-hidden')).toBe('true');
    expect(container.querySelectorAll('[data-adam="verse"]').length).toBe(COMMUNITY_VERSES.length);
    const sr = container.querySelector('.verse-sr');
    expect(sr.getAttribute('aria-label')).toBe(VERSE_LABEL);
    expect(sr.querySelectorAll('li').length).toBe(COMMUNITY_VERSES.length);
    // widgets start hidden: nothing flashes before the first painted frame
    expect(VERSE_CSS).toMatch(/\.verse-descent \.verse \{[^}]*visibility: hidden; opacity: 0/);
  });
  test('stacked layout constants: single column, max 640px, on the join colour', () => {
    expect(VERSE_CSS).toMatch(/\.verse-stack-list \{[^}]*max-width: 640px/);
    expect(VERSE_CSS).toMatch(/\.verse-stack \{[^}]*background: #EBC480/);
    expect(VERSE_STACK_QUERY).toBe('(prefers-reduced-motion: reduce), (max-height: 520px) and (orientation: landscape)');
  });
  test('mobile CSS: 360px cap and smaller blur', () => {
    expect(VERSE_CSS).toMatch(/width: min\(360px, calc\(100cqw - 32px\)\)/);
    expect(VERSE_CSS).toMatch(/blur\(14px\)/);
  });
});

describe('prerender / SSR', () => {
  test('AdamHands server markup includes the stacked verses (readable without JS) and is hydration-stable', () => {
    const html = renderToStaticMarkup(<AdamHands />);
    expect(html).toContain('data-testid="verse-stack"');
    for (const v of COMMUNITY_VERSES) expect(html).toContain(v.ref);
    expect(html).not.toContain('data-adam="verses"');
    expect(html.replace(/<style>[\s\S]*?<\/style>/, '')).not.toContain('verse-sr');
    expect(renderToString(<AdamHands />).replace(/<!-- -->/g, '')).toBe(html);
  });
});

describe('paintVerses', () => {
  const mk = () => { const c = render(<VerseDescent />); return [...c.container.querySelectorAll('[data-adam="verse"]')]; };
  test('before the verse phase every widget stays hidden', () => {
    const els = mk(); paintVerses(els, VERSE_START_P - 0.01, false, 1600, 900);
    els.forEach((el) => expect(el.style.visibility).toBe('hidden'));
  });
  test('mid phase: widgets visible in order, centres in stage px, first is lowest', () => {
    const els = mk(); paintVerses(els, VERSE_START_P + 0.2 * VERSE_SPAN_P.desktop, false, 1600, 900);
    const shown = els.filter((el) => el.style.visibility === 'visible');
    expect(shown.length).toBeGreaterThanOrEqual(1);
    expect(els[0].style.visibility).toBe('visible');
    expect(els[0].style.transform).toMatch(/translate3d\(-?\d+(\.\d+)?px, -?\d+(\.\d+)?px, 0\) translate\(-50%, -50%\) scale\(\d+(\.\d+)?\)/);
    expect(els[0].style.getPropertyValue('--va')).not.toBe('');
  });
  test('after the phase all hidden again, so reverse scroll restores exactly', () => {
    const els = mk();
    paintVerses(els, 1.8, false, 1600, 900);
    paintVerses(els, P_END.desktop, false, 1600, 900);
    els.forEach((el) => expect(el.style.visibility).toBe('hidden'));
    paintVerses(els, 1.8, false, 1600, 900);
    expect(els.some((el) => el.style.visibility === 'visible')).toBe(true);
  });
  test('mobile: the card sits near the centre column and has no glass backdrop', () => {
    const els = mk(); paintVerses(els, VERSE_START_P + 0.1 * VERSE_SPAN_P.mobile, true, 390, 844);
    const tx = parseFloat(els[0].style.transform.match(/translate3d\(([-\d.]+)px/)[1]);
    expect(Math.abs(tx - 0.5 * 390)).toBeLessThan(0.1 * 390);
    expect(els[0].dataset.bf).toBe('off');
    expect(els[0].style.getPropertyValue('--va')).toBe('0.930');
  });
  test('distance: a far card is blurred and dimmer than a near one; reverse restores', () => {
    const els = mk();
    paintVerses(els, VERSE_START_P + 0.05 * VERSE_SPAN_P.desktop, false, 1600, 900);
    const near = { f: els[0].style.filter, o: els[0].style.opacity };
    paintVerses(els, VERSE_START_P + 0.25 * VERSE_SPAN_P.desktop, false, 1600, 900); // card 0 about 55% through its travel
    expect(els[0].style.filter).toMatch(/blur\(/);
    expect(parseFloat(els[0].style.opacity)).toBeLessThan(parseFloat(near.o));
    paintVerses(els, VERSE_START_P + 0.05 * VERSE_SPAN_P.desktop, false, 1600, 900);
    expect(els[0].style.filter).toBe(near.f); expect(els[0].style.opacity).toBe(near.o);
  });
});
