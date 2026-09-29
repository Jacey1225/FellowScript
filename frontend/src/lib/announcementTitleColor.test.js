// Task 20260929-announcement-title-color-crop-layer-fix testing.
// Run: cd frontend && npx vitest run src/lib/announcementTitleColor.test.js
import { describe, test, expect } from 'vitest';
import {
  TITLE_COLOR_DEFAULT, TITLE_COLOR_SWATCHES, isValidHex, normalizeHex, isDefaultColor, contrastRatio,
  needsLegibilityWarning, colorName, bannerColor, surfaceColor, SCRIM_WORST_CASE,
} from './announcementTitleColor.js';

const BAD = ['#FFF', 'red', 'red; background:url(x)', 'javascript:alert(1)', '#GGGGGG', '#12345', '#1234567', 'FFFFFF',
  ' #FFFFFF', '#FFFFFF ', '#FFFFFF\n', '#ＦＦＦＦＦＦ', '#FFFFFF;x', 'url(#FFFFFF)', '', null, undefined, 123, {}, ['#FFFFFF']];

describe('strict hex validation', () => {
  test('accepts only #RRGGBB in either case', () => {
    expect(isValidHex('#ffc61a')).toBe(true);
    expect(isValidHex('#FFC61A')).toBe(true);
    for (const b of BAD) expect(isValidHex(b)).toBe(false);
  });
  test('normalizeHex uppercases valid and returns null for everything else', () => {
    expect(normalizeHex('#ffc61a')).toBe('#FFC61A');
    for (const b of BAD) expect(normalizeHex(b)).toBeNull();
  });
  test('bannerColor falls back to the default and never echoes a raw string', () => {
    expect(bannerColor('#9cd3ff')).toBe('#9CD3FF');
    for (const b of BAD) expect(bannerColor(b)).toBe(TITLE_COLOR_DEFAULT);
  });
  test('isDefaultColor: null/invalid/default are default', () => {
    expect(isDefaultColor(null)).toBe(true);
    expect(isDefaultColor('nope')).toBe(true);
    expect(isDefaultColor('#f2f2f2')).toBe(true);
    expect(isDefaultColor('#FFC61A')).toBe(false);
  });
});

describe('contrast and warnings', () => {
  test('contrastRatio known values', () => {
    expect(contrastRatio('#000000', '#FFFFFF')).toBeCloseTo(21, 1);
    expect(contrastRatio('#FFFFFF', '#FFFFFF')).toBeCloseTo(1, 5);
    expect(contrastRatio('bad', '#FFFFFF')).toBeNull();
  });
  test('every curated swatch passes AA vs worst-case scrim and none warns', () => {
    for (const s of TITLE_COLOR_SWATCHES) {
      expect(contrastRatio(s.hex, SCRIM_WORST_CASE)).toBeGreaterThanOrEqual(4.5);
      expect(needsLegibilityWarning(s.hex)).toBe(false);
    }
  });
  test('dark custom color warns; invalid does not', () => {
    expect(needsLegibilityWarning('#222222')).toBe(true);
    expect(needsLegibilityWarning('#474747')).toBe(true);
    expect(needsLegibilityWarning('junk')).toBe(false);
  });
  test('swatches have unique hex, unique names, default first', () => {
    expect(TITLE_COLOR_SWATCHES[0].hex).toBe(TITLE_COLOR_DEFAULT);
    expect(new Set(TITLE_COLOR_SWATCHES.map(s => s.hex)).size).toBe(TITLE_COLOR_SWATCHES.length);
    expect(new Set(TITLE_COLOR_SWATCHES.map(s => s.name)).size).toBe(TITLE_COLOR_SWATCHES.length);
    for (const s of TITLE_COLOR_SWATCHES) expect(isValidHex(s.hex)).toBe(true);
  });
  test('colorName', () => {
    expect(colorName(null)).toBe('Parchment (default)');
    expect(colorName('#ffc61a')).toBe('Gold');
    expect(colorName('#123456')).toBe('Custom color #123456');
  });
});

describe('surfaceColor (list row / viewer)', () => {
  test('null, invalid and default inherit theme text', () => {
    for (const v of [null, undefined, 'x; color:red', '#F2F2F2', '#f2f2f2']) {
      expect(surfaceColor(v, false)).toBeUndefined();
      expect(surfaceColor(v, true)).toBeUndefined();
    }
  });
  test('AA-passing color is used; failing color falls back to theme text', () => {
    expect(surfaceColor('#FFC61A', false)).toBe('#FFC61A');    // gold on dark surface passes
    expect(surfaceColor('#FFC61A', true)).toBeUndefined();     // gold on white fails
    expect(surfaceColor('#9CD3FF', false)).toBe('#9CD3FF');    // dark surface
    expect(surfaceColor('#9CD3FF', true)).toBeUndefined();     // light surface
    expect(surfaceColor('#0B3D91', true)).toBe('#0B3D91');
    expect(surfaceColor('#0B3D91', false)).toBeUndefined();
  });
});
