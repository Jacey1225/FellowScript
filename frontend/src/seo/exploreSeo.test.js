import { describe, test, expect } from 'vitest';
import { isExploreBrowseBuildFlagOn, exploreRobots, exploreJsonLd, EXPLORE_SEO_PATH, EXPLORE_ROUTE } from './exploreSeo.js';

describe('exploreSeo build flag', () => {
  test('only explicit true/1 enables indexing; everything else fails closed', () => {
    for (const v of ['true', 'TRUE', ' 1 ', '1']) expect(isExploreBrowseBuildFlagOn(v)).toBe(true);
    for (const v of [undefined, null, '', 'false', '0', 'yes', 'on', 'truee']) expect(isExploreBrowseBuildFlagOn(v)).toBe(false);
  });
  test('robots value', () => {
    expect(exploreRobots(true)).toBe('index, follow');
    expect(exploreRobots(false)).toBe('noindex, nofollow');
  });
  test('paths and truthful JSON-LD (no listing counts or named groups)', () => {
    expect(EXPLORE_SEO_PATH).toBe('/explore/');
    expect(EXPLORE_ROUTE).toBe('/explore');
    const ld = exploreJsonLd('https://fellowscript.com');
    expect(ld[0].url).toBe('https://fellowscript.com/explore/');
    expect(JSON.stringify(ld)).not.toMatch(/numberOfItems|itemListElement|ItemList|\d{2,} groups/);
  });
});
