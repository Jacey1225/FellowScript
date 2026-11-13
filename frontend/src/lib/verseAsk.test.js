import { describe, it, expect } from 'vitest';
import {
  placeVerseAskOverlay, placeVerseAskColumn, verseContextFromSpan, verseAskErrorCopy, VerseAskError,
} from './verseAsk.js';

const vp = { height: 800 };

describe('placeVerseAskOverlay', () => {
  it('puts the pill just above the verse and the panel below it', () => {
    const r = placeVerseAskOverlay({ verseRect: { top: 300, bottom: 340 }, viewport: vp, pillH: 44, panelH: 200 });
    expect(r.pillTop).toBe(300 - 6 - 44);
    expect(r.panelTop).toBe(r.pillTop + 44 + 6);
    expect(r.flipped).toBe(false);
  });
  it('clamps the pill on screen when the verse is at the top (overlays, never pushes)', () => {
    const r = placeVerseAskOverlay({ verseRect: { top: 10, bottom: 50 }, viewport: vp, pillH: 44, panelH: 200 });
    expect(r.pillTop).toBe(8);
    expect(r.panelTop).toBe(8 + 44 + 6);
  });
  it('flips the panel above the pill near the bottom and keeps it on screen', () => {
    const r = placeVerseAskOverlay({ verseRect: { top: 740, bottom: 780 }, viewport: vp, pillH: 44, panelH: 300 });
    expect(r.flipped).toBe(true);
    expect(r.panelTop).toBeGreaterThanOrEqual(8);
    expect(r.panelTop + Math.min(300, r.panelMaxH)).toBeLessThanOrEqual(r.pillTop);
  });
  it('keeps the pill above the keyboard', () => {
    const r = placeVerseAskOverlay({ verseRect: { top: 700, bottom: 740 }, viewport: vp, keyboardTop: 500, pillH: 44, panelH: 100 });
    expect(r.pillTop + 44).toBeLessThanOrEqual(500 - 8);
  });
  it('caps panel height at 45 percent of the viewport', () => {
    const r = placeVerseAskOverlay({ verseRect: { top: 100, bottom: 140 }, viewport: vp, pillH: 44, panelH: 900 });
    expect(r.panelMaxH).toBeLessThanOrEqual(360);
  });
  it('is pure: same input, same output', () => {
    const a = { verseRect: { top: 300, bottom: 340 }, viewport: vp, pillH: 44, panelH: 200 };
    expect(placeVerseAskOverlay(a)).toEqual(placeVerseAskOverlay({ ...a }));
  });
});

describe('placeVerseAskColumn', () => {
  it('caps width at 520 and clamps to the viewport margin', () => {
    expect(placeVerseAskColumn({ columnRect: { left: 100, width: 900 }, viewportWidth: 1200 })).toEqual({ left: 100, width: 520 });
    expect(placeVerseAskColumn({ columnRect: { left: 0, width: 300 }, viewportWidth: 320 })).toEqual({ left: 8, width: 300 });
  });
});

describe('verseContextFromSpan', () => {
  it('drops the verse number and builds the reference', () => {
    const span = document.createElement('span');
    span.id = 'vs16';
    span.innerHTML = '<sup class="vnum" data-v="16">16</sup> For God so loved  the world';
    expect(verseContextFromSpan(span, 'John', 3)).toEqual({ verseNum: 16, reference: 'John 3:16', text: 'For God so loved the world' });
  });
});

describe('verseAskErrorCopy', () => {
  it('uses warm copy', () => {
    expect(verseAskErrorCopy(new VerseAskError('offline'))).toMatch(/offline/i);
    expect(verseAskErrorCopy(new VerseAskError('network'))).toMatch(/Try again/);
    expect(verseAskErrorCopy(new VerseAskError('server', 'Too many messages. Slow down.'))).toMatch(/asked a lot/);
    expect(verseAskErrorCopy(new VerseAskError('server', 'That question is too long.'))).toBe('That question is too long.');
  });
});
