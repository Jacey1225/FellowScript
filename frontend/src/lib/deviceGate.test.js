// Unit tests for the isMobileUserAgent() regex behind MobileBlockGate.jsx.
// Run with: cd frontend && npm test -- --run src/lib/deviceGate.test.js
import { describe, test, expect } from 'vitest';
import { isMobileUserAgent } from './deviceGate.js';

const IPHONE_SAFARI =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';
const ANDROID_CHROME =
  'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36';
const DESKTOP_CHROME_MAC =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';
const DESKTOP_FIREFOX_WIN =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:126.0) Gecko/20100101 Firefox/126.0';
// iPadOS Safari has reported itself as a Mac UA since iPadOS 13 — see the
// comment in deviceGate.js on why this is intentionally treated as desktop.
const IPADOS_SAFARI =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15';

describe('isMobileUserAgent', () => {
  test('flags common phone UAs', () => {
    expect(isMobileUserAgent(IPHONE_SAFARI)).toBe(true);
    expect(isMobileUserAgent(ANDROID_CHROME)).toBe(true);
  });

  test('does not flag desktop browser UAs', () => {
    expect(isMobileUserAgent(DESKTOP_CHROME_MAC)).toBe(false);
    expect(isMobileUserAgent(DESKTOP_FIREFOX_WIN)).toBe(false);
  });

  test('does not flag iPadOS Safari (masquerades as Mac, treated as desktop-capable)', () => {
    expect(isMobileUserAgent(IPADOS_SAFARI)).toBe(false);
  });

  test('treats a missing/empty UA as non-mobile rather than throwing', () => {
    expect(isMobileUserAgent('')).toBe(false);
    expect(isMobileUserAgent(undefined)).toBe(false);
  });
});
