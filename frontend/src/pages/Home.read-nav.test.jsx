// Regression coverage for task 20260921-read-nav-native-app-redirect.
//
// Before this task, both "Read" nav links (header pill, footer) were a
// react-router <Link to="/reader">, which sent every visitor — including
// mobile UAs — into the in-browser Reader (where mobile then hit
// MobileBlockGate.jsx's block screen; see frontend.json step 1 diagnosis).
// This proves the replacement device-branching behavior: a mobile UA gets a
// real external link to the App Store listing instead of /reader, and a
// desktop UA gets a same-page anchor to the existing "On your desktop"
// section instead of /reader. Follows the UA-mocking pattern established in
// MobileBlockGate.test.jsx and deviceGate.test.js (same isMobileUserAgent()
// mechanism, deliberately not the viewport-based useIsDesktopViewport()).
//
// Run with: cd frontend && npm test -- --run src/pages/Home.read-nav.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach, beforeEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import Home from './Home.jsx';

vi.mock('../context/AuthContext.jsx', () => ({
  useAuth: () => ({ user: null }),
}));

const APP_STORE_URL = 'https://apps.apple.com/us/app/fellowscript-study-connect/id6791701454';
const DESKTOP_DOWNLOAD_ANCHOR = '#desktop-download';

const IPHONE_SAFARI =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';
const ANDROID_CHROME =
  'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36';
const DESKTOP_CHROME_MAC =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';
const DESKTOP_FIREFOX_WIN =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:126.0) Gecko/20100101 Firefox/126.0';

let originalUA;

beforeEach(() => {
  originalUA = window.navigator.userAgent;
});

afterEach(() => {
  cleanup();
  Object.defineProperty(window.navigator, 'userAgent', { value: originalUA, configurable: true });
});

function setUserAgent(ua) {
  Object.defineProperty(window.navigator, 'userAgent', { value: ua, configurable: true });
}

function renderHome() {
  return render(
    <MemoryRouter initialEntries={['/']}>
      <Home />
    </MemoryRouter>
  );
}

// Both "Read" links (header pill nav, footer nav column) render the text
// "Read" — grab them by role/name rather than relying on DOM position so the
// assertions don't depend on which one text order picks up first.
function getReadLinks() {
  return screen.getAllByRole('link', { name: 'Read' });
}

describe('Home — "Read" nav device redirect (mobile UA)', () => {
  test('both Read links open the App Store listing as a real external link, never /reader', () => {
    setUserAgent(IPHONE_SAFARI);
    renderHome();

    const links = getReadLinks();
    expect(links.length).toBe(2);
    links.forEach((link) => {
      expect(link.getAttribute('href')).toBe(APP_STORE_URL);
      expect(link.getAttribute('target')).toBe('_blank');
      expect(link.getAttribute('rel')).toBe('noopener noreferrer');
      expect(link.getAttribute('href')).not.toMatch(/\/reader/);
    });
  });

  test('also branches correctly for an Android UA, not just iPhone', () => {
    setUserAgent(ANDROID_CHROME);
    renderHome();

    getReadLinks().forEach((link) => {
      expect(link.getAttribute('href')).toBe(APP_STORE_URL);
    });
  });
});

describe('Home — "Read" nav device redirect (desktop UA)', () => {
  test('both Read links anchor to the existing "On your desktop" section, never /reader', () => {
    setUserAgent(DESKTOP_CHROME_MAC);
    const { container } = renderHome();

    const links = getReadLinks();
    expect(links.length).toBe(2);
    links.forEach((link) => {
      expect(link.getAttribute('href')).toBe(DESKTOP_DOWNLOAD_ANCHOR);
      expect(link.hasAttribute('target')).toBe(false);
      expect(link.getAttribute('href')).not.toMatch(/\/reader/);
    });

    // The anchor target actually exists on the page so the link resolves to
    // real content instead of a dead fragment.
    expect(container.querySelector('#desktop-download')).toBeTruthy();
  });

  test('also branches correctly for a Windows/Firefox UA', () => {
    setUserAgent(DESKTOP_FIREFOX_WIN);
    renderHome();

    getReadLinks().forEach((link) => {
      expect(link.getAttribute('href')).toBe(DESKTOP_DOWNLOAD_ANCHOR);
    });
  });
});

describe('Home — "Read" nav device redirect (unaffected controls)', () => {
  test('the "Read scripture" hero CTA is unchanged — still an in-app link to /reader, unlike the nav', () => {
    setUserAgent(IPHONE_SAFARI);
    renderHome();

    const cta = screen.getByRole('link', { name: /Read scripture/i });
    expect(cta.getAttribute('href')).toBe('/reader');
  });
});
