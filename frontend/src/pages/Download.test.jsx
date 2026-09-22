// Regression test for the new /download page (task
// 20260922-reader-nav-download-page). Supersedes
// Home.download-section.test.jsx (task 20260902-download-section-implementation)
// — the "On your desktop" section it covered was relocated wholesale from
// Home.jsx to here (design-notes.md §3/§4), so its assertions move here too.
//
// Covers the acceptance criteria that are cheap to assert in jsdom:
//  - a mobile UA gets the tailored mobile branch: a real external App Store
//    link, and never anything that renders or links to /reader;
//  - a desktop UA gets both platform cards, unchanged from their prior
//    Home.jsx incarnation — the macOS card's real, live <a download> control
//    pointing at the real GitHub Release asset URL, its metadata line
//    carrying only the two verified facts (architecture, file size) with no
//    OS-version claim, and the Windows card carrying no interactive
//    semantics at all (no button/link/tabIndex/role="button" anywhere
//    inside it);
//  - neither branch ever renders a link to /reader.
//
// Run with: cd frontend && npm test -- --run src/pages/Download.test.jsx
import React from 'react';
import { describe, test, expect, afterEach, beforeEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import Download from './Download.jsx';

const APP_STORE_URL = 'https://apps.apple.com/us/app/fellowscript-study-connect/id6791701454';
const MACOS_DOWNLOAD_URL = 'https://github.com/Jacey1225/FellowScript/releases/download/desktop-v0.1.0/FellowScript.dmg';

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

function renderDownload() {
  return render(
    <MemoryRouter initialEntries={['/download']}>
      <Download />
    </MemoryRouter>
  );
}

describe('Download — mobile branch', () => {
  test('iPhone UA: renders one primary CTA to the real App Store listing, never /reader', () => {
    setUserAgent(IPHONE_SAFARI);
    const { container } = renderDownload();

    const cta = screen.getByRole('link', { name: /Get it on the App Store/i });
    expect(cta.getAttribute('href')).toBe(APP_STORE_URL);
    expect(cta.getAttribute('target')).toBe('_blank');
    expect(cta.getAttribute('rel')).toBe('noopener noreferrer');
    expect(container.querySelector('a[href="/reader"]')).toBeNull();
  });

  test('Android UA also gets the mobile branch, not just iPhone', () => {
    setUserAgent(ANDROID_CHROME);
    renderDownload();

    expect(screen.getByRole('link', { name: /Get it on the App Store/i })).toBeTruthy();
    expect(screen.queryByText('MACOS')).toBeNull();
    expect(screen.queryByText('WINDOWS')).toBeNull();
  });

  test('mobile branch never renders the desktop platform cards', () => {
    setUserAgent(IPHONE_SAFARI);
    renderDownload();

    expect(screen.queryByText('// ON YOUR DESKTOP')).toBeNull();
  });
});

describe('Download — desktop branch (relocated from Home.jsx verbatim)', () => {
  test('Mac Chrome UA: renders the eyebrow, headline, and both platform cards', () => {
    setUserAgent(DESKTOP_CHROME_MAC);
    renderDownload();

    expect(screen.getByText('// ON YOUR DESKTOP')).toBeTruthy();
    expect(screen.getByText('MACOS')).toBeTruthy();
    expect(screen.getByText('WINDOWS')).toBeTruthy();
    expect(screen.getByText('Coming soon')).toBeTruthy();
  });

  test('Windows Firefox UA also gets the desktop branch, not just Mac Chrome', () => {
    setUserAgent(DESKTOP_FIREFOX_WIN);
    renderDownload();

    expect(screen.getByText('// ON YOUR DESKTOP')).toBeTruthy();
  });

  test('macOS card exposes a working <a download> control pointing at the live release URL', () => {
    setUserAgent(DESKTOP_CHROME_MAC);
    renderDownload();

    const link = screen.getByRole('link', { name: /Download for Mac/i });
    expect(link).toBeTruthy();
    expect(link.hasAttribute('download')).toBe(true);
    expect(link.getAttribute('href')).toBe(MACOS_DOWNLOAD_URL);
  });

  test('macOS metadata line carries only verified facts, no OS-version claim', () => {
    setUserAgent(DESKTOP_CHROME_MAC);
    renderDownload();

    expect(screen.getByText('Apple silicon & Intel · 3 MB')).toBeTruthy();
    expect(screen.queryByText(/macOS ⟨MIN VERSION/)).toBeNull();
    expect(screen.queryByText(/macOS \d/)).toBeNull();
  });

  test('Windows card has no interactive semantics anywhere inside it', () => {
    setUserAgent(DESKTOP_CHROME_MAC);
    const { container } = renderDownload();

    const windowsLabel = screen.getByText('WINDOWS');
    const card = windowsLabel.closest('.dl-card:not(.dl-card-mac)') || container.querySelector('.dl-card:not(.dl-card-mac)');
    expect(card).toBeTruthy();
    expect(card.querySelector('a, button, [tabindex], [role="button"]')).toBeFalsy();
  });

  test('desktop branch never renders the mobile App Store CTA or a /reader link', () => {
    setUserAgent(DESKTOP_CHROME_MAC);
    const { container } = renderDownload();

    expect(screen.queryByRole('link', { name: /Get it on the App Store/i })).toBeNull();
    expect(container.querySelector('a[href="/reader"]')).toBeNull();
  });
});

describe('Download — persistent, shallow nav back to Home', () => {
  test('the sticky header always renders a "Back to Home" link to "/"', () => {
    setUserAgent(DESKTOP_CHROME_MAC);
    renderDownload();

    const back = screen.getByRole('link', { name: /Back to Home/i });
    expect(back.getAttribute('href')).toBe('/');
  });
});
