import { describe, test, expect } from 'vitest';
import fixtures from '../../../shared/linkify-fixtures.json';
import { linkifySegments, linkInfo, isSafeHttpUrl, MAX_SCAN_CHARS } from './linkify.js';

describe('linkify shared fixtures', () => {
  for (const c of fixtures.cases) {
    test(c.name, () => {
      const got = linkifySegments(c.input).map((s) => [s.type, s.text]);
      expect(got).toEqual(c.segments);
      expect(got.map((s) => s[1]).join('')).toBe(c.input);
    });
  }
  for (const c of fixtures.suspicious) {
    test(`linkInfo ${c.url}`, () => {
      const info = linkInfo(c.url);
      expect(info.suspicious).toBe(c.suspicious);
      expect(info.host).toBe(c.host);
    });
  }
});

describe('linkify bounds', () => {
  test('100k chars finish quickly and stay linear', () => {
    for (const body of ['https://a.com/' + ')'.repeat(100000), 'https://'.repeat(20000), 'x'.repeat(100000), '(' .repeat(50000) + 'https://a.com' + ')'.repeat(50000)]) {
      const t0 = Date.now();
      linkifySegments(body);
      expect(Date.now() - t0).toBeLessThan(1000);
    }
  });
  test('a url cut by the scan cap is not linked', () => {
    const s = `https://a.com/${'a'.repeat(MAX_SCAN_CHARS + 10)}`;
    expect(linkifySegments(s)).toEqual([{ type: 'text', text: s }]);
  });
  test('isSafeHttpUrl', () => {
    expect(isSafeHttpUrl('https://a.com')).toBe(true);
    expect(isSafeHttpUrl('javascript:alert(1)')).toBe(false);
    expect(isSafeHttpUrl('/relative')).toBe(false);
    expect(isSafeHttpUrl(undefined)).toBe(false);
  });
});
