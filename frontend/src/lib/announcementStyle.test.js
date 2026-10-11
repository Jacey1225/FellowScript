// Task 20260929 web-announcements-parity testing.
// Run: cd frontend && npx vitest run src/lib/announcementStyle.test.js
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  BG_THEMES, BG_THEME_GRADIENTS, BG_THEME_SOLIDS, TITLE_FONTS, TITLE_FONT_KEYS, EXTRAS_LIMITS,
  resolveBgTheme, bgThemeStoredKey, bgThemeCss, bgThemeIsGradient, bgThemeReadableText, bgThemeWorstCaseHex,
  resolveTitleFont, titleFontStoredKey, titleFontStyle, parseLink, linkError, handleError, locationError,
  locationMapsUrl, isLookalikeHost, linkDisplayHost, titleColorOnTheme, PARCHMENT_HEX,
} from './announcementStyle.js';
import { contrastRatio } from './announcementTitleColor.js';
import { rsvpJoin, rsvpLeave } from './announcementsApi.js';

describe('bg themes', () => {
  test('exactly the 13 allowed keys', () => {
    expect(Object.keys(BG_THEMES).sort()).toEqual(
      ['none', 'ember', 'dusk', 'forest', 'ocean', 'plum', 'slate', 'espresso', 'moss', 'navy', 'wine', 'graphite', 'ink'].sort());
    expect(BG_THEME_GRADIENTS).toHaveLength(6);
    expect(BG_THEME_SOLIDS).toHaveLength(6);
  });
  test('unknown, legacy, prototype and non-string keys resolve to none', () => {
    for (const k of ['bogus', '__proto__', 'constructor', 'toString', '', null, undefined, 5, {}]) {
      expect(resolveBgTheme(k)).toBe('none');
      expect(bgThemeCss(k)).toBeNull();
    }
  });
  test('stored key is null for none, key otherwise', () => {
    expect(bgThemeStoredKey('none')).toBeNull();
    expect(bgThemeStoredKey('x')).toBeNull();
    expect(bgThemeStoredKey('wine')).toBe('wine');
  });
  test('gradients vs solids css', () => {
    expect(bgThemeIsGradient('ember')).toBe(true);
    expect(bgThemeCss('ember')).toMatch(/^linear-gradient\(135deg, #[0-9A-F]{6}, #[0-9A-F]{6}\)$/);
    expect(bgThemeCss('ink')).toBe('#101010');
  });
  test('readable text meets AA against every theme worst case', () => {
    for (const k of Object.keys(BG_THEMES)) {
      const bg = bgThemeWorstCaseHex(k);
      if (!bg) { expect(bgThemeReadableText(k)).toBe(PARCHMENT_HEX); continue; }
      expect(contrastRatio(bgThemeReadableText(k), bg)).toBeGreaterThanOrEqual(4.5);
    }
  });
  test('titleColorOnTheme falls back for low contrast or invalid hex', () => {
    expect(titleColorOnTheme('#101010', 'ink', '#F5EAD0')).toBe('#F5EAD0');
    expect(titleColorOnTheme('javascript:x', 'ink', '#F5EAD0')).toBe('#F5EAD0');
    expect(titleColorOnTheme('#ffc61a', 'ink', '#F5EAD0')).toBe('#FFC61A');
  });
});

describe('title fonts', () => {
  test('exactly the 8 allowed keys, each with a fallback stack', () => {
    expect(TITLE_FONT_KEYS.sort()).toEqual(['bebas', 'default', 'dancing', 'lora', 'nunito', 'oswald', 'playfair', 'schibsted'].sort());
    for (const k of TITLE_FONT_KEYS) if (k !== 'default') expect(TITLE_FONTS[k].family).toMatch(/,\s*[^,]+$/);
  });
  test('unknown keys resolve to default with empty style', () => {
    for (const k of ['comic', '__proto__', null, 3]) {
      expect(resolveTitleFont(k)).toBe('default');
      expect(titleFontStyle(k)).toEqual({});
      expect(titleFontStoredKey(k)).toBeNull();
    }
    expect(titleFontStoredKey('lora')).toBe('lora');
    expect(titleFontStyle('bebas').fontFamily).toContain('Bebas Neue');
  });
});

describe('links, handles, location', () => {
  test('parseLink accepts http(s) and bare hosts only', () => {
    expect(parseLink('example.com')).toBe('https://example.com/');
    expect(parseLink('http://a.org/x?y=1')).toBe('http://a.org/x?y=1');
  });
  test('parseLink rejects unsafe or malformed input', () => {
    const bad = ['javascript:alert(1)', 'JaVaScRiPt://x.com', 'data:text/html,hi', 'file:///etc/passwd', 'ftp://a.com',
      'https://user:pw@a.com', 'https://localhost', 'a b.com', 'https://a.com/ok\nevil','https://a.com/\u0000', '', '   ', null, undefined, 5,
      'https://.a.com', 'https://a.com.', `https://a.com/${'x'.repeat(EXTRAS_LIMITS.maxLinkLength)}`];
    for (const b of bad) expect(parseLink(b)).toBeNull();
    expect(linkError('javascript:alert(1)')).toBeTruthy();
    expect(linkError('')).toBeNull();
    expect(linkError('example.com')).toBeNull();
  });
  test('lookalike hosts flagged, display host strips www', () => {
    expect(isLookalikeHost('xn--pple-43d.com')).toBe(true);
    expect(isLookalikeHost('аpple.com')).toBe(true);
    expect(isLookalikeHost('apple.com')).toBe(false);
    expect(linkDisplayHost('https://www.Example.com/a')).toBe('example.com');
  });
  test('handleError rejects card-number-like and over-length', () => {
    expect(handleError('@jacey')).toBeNull();
    expect(handleError('')).toBeNull();
    expect(handleError('4111 1111 1111 1111')).toBeTruthy();
    expect(handleError('a'.repeat(65))).toBeTruthy();
  });
  test('location control chars rejected; maps url encodes', () => {
    expect(locationError('Main St')).toBeNull();
    expect(locationError('a\u0007b')).toBeTruthy();
    expect(locationMapsUrl('  ')).toBeNull();
    const u = locationMapsUrl('A&B "x" #1');
    expect(u).toBe('https://www.google.com/maps/search/?api=1&query=A%26B%20%22x%22%20%231');
  });
});

describe('rsvp api', () => {
  let f;
  beforeEach(() => { f = vi.fn(); vi.stubGlobal('fetch', f); });
  afterEach(() => vi.unstubAllGlobals());
  test('join POSTs, leave DELETEs the rsvp endpoint', async () => {
    f.mockResolvedValue({ ok: true, status: 200, json: async () => ({ rsvp_joined: true }) });
    await expect(rsvpJoin('u', 'g', 'a1')).resolves.toEqual({ rsvp_joined: true });
    expect(f.mock.calls[0][0]).toMatch(/\/a1\/rsvp$/);
    expect(f.mock.calls[0][1].method).toBe('POST');
    await rsvpLeave('u', 'g', 'a1');
    expect(f.mock.calls[1][1].method).toBe('DELETE');
  });
  test('409 full surfaces as thrown error, no fabricated success', async () => {
    f.mockResolvedValue({ ok: false, status: 409, json: async () => ({ detail: 'Event is full' }) });
    await expect(rsvpJoin('u', 'g', 'a1')).rejects.toMatchObject({ status: 409, message: 'Event is full' });
  });
  test('422 gate-off message surfaced', async () => {
    f.mockResolvedValue({ ok: false, status: 422, json: async () => ({ detail: 'Feature not available' }) });
    await expect(rsvpJoin('u', 'g', 'a1')).rejects.toMatchObject({ status: 422, message: 'Feature not available' });
  });
});
