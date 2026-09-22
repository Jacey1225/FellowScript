// Regression coverage for task 20260922-reader-nav-download-page, superseding
// the device-branching behavior task 20260921-read-nav-native-app-redirect
// originally put here.
//
// Before this task, the two "Read" nav links (header pill, footer) each
// branched by device UA: mobile got a real external App Store link, desktop
// got a same-page `#desktop-download` anchor into Home's own "On your
// desktop" section — neither ever reached `/reader` directly, but the
// desktop branch was a same-page anchor rather than a real, linkable route,
// and the "Read scripture"/"Read the Bible" CTAs were left as unconditional,
// ungated `<PillButton to="/reader">` links with no device branching at all.
//
// This proves the replacement behavior (design-notes.md §4): both nav links
// now collapse to a single ordinary `<Link to="/download">`, regardless of
// UA — `/download` itself owns the device branching now (see
// Download.test.jsx) — and the two CTAs are repointed at `/download` too,
// while the auth-gated CTAs (Open app/Get started/Begin your journey/Start a
// group/Join free) are confirmed untouched.
//
// Run with: cd frontend && npm test -- --run src/pages/Home.read-nav.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach, beforeEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import Home from './Home.jsx';

// Toggleable per-test, same convention as AppNav.desktop-scope.test.jsx's
// mockUseAuth — lets the last describe block below assert the signed-in
// case without a separate module-reset dance.
const mockUseAuth = vi.fn(() => ({ user: null }));
vi.mock('../context/AuthContext.jsx', () => ({
  useAuth: () => mockUseAuth(),
}));

const IPHONE_SAFARI =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';
const DESKTOP_CHROME_MAC =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

let originalUA;

beforeEach(() => {
  originalUA = window.navigator.userAgent;
  mockUseAuth.mockReturnValue({ user: null });
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

describe('Home — "Read" nav links route to /download regardless of device (task 20260922-reader-nav-download-page)', () => {
  test('mobile UA: both Read links are a plain internal Link to /download, never /reader or an external App Store href', () => {
    setUserAgent(IPHONE_SAFARI);
    renderHome();

    const links = getReadLinks();
    expect(links.length).toBe(2);
    links.forEach((link) => {
      expect(link.getAttribute('href')).toBe('/download');
      expect(link.hasAttribute('target')).toBe(false);
    });
  });

  test('desktop UA: both Read links are the same plain internal Link to /download, never /reader or a #desktop-download anchor', () => {
    setUserAgent(DESKTOP_CHROME_MAC);
    const { container } = renderHome();

    const links = getReadLinks();
    expect(links.length).toBe(2);
    links.forEach((link) => {
      expect(link.getAttribute('href')).toBe('/download');
    });
    // The old same-page anchor target no longer exists on Home at all — the
    // section moved to Download.jsx wholesale (design-notes.md §3/§4).
    expect(container.querySelector('#desktop-download')).toBeNull();
  });
});

describe('Home — "Read scripture"/"Read the Bible" CTAs also route to /download (previously deferred, now resolved)', () => {
  test('the "Read scripture" hero CTA now points at /download, not /reader', () => {
    renderHome();

    const cta = screen.getByRole('link', { name: /Read scripture/i });
    expect(cta.getAttribute('href')).toBe('/download');
  });

  test('the "Read the Bible" closing CTA now points at /download, not /reader', () => {
    renderHome();

    const cta = screen.getByRole('link', { name: /Read the Bible/i });
    expect(cta.getAttribute('href')).toBe('/download');
  });
});

describe('Home — auth-gated CTAs unaffected by this task (design-notes.md §4)', () => {
  test('signed out: "Get started"/"Begin your journey"/"Start a group"/"Join free" all still route to /signin, not /download', () => {
    renderHome();

    for (const name of [/Get started/i, /Begin your journey/i, /Start a group/i, /Join free/i]) {
      const cta = screen.getByRole('link', { name });
      expect(cta.getAttribute('href')).toBe('/signin');
    }
  });
});

describe('Home — signed-in auth-gated CTA still reaches /reader directly (accepted, documented exception)', () => {
  test('signed in: "Open app" routes straight to /reader, unaffected by this task', () => {
    mockUseAuth.mockReturnValue({ user: { user_id: 'u1', username: 'jaceysimpson' } });
    renderHome();

    const cta = screen.getByRole('link', { name: /Open app/i });
    expect(cta.getAttribute('href')).toBe('/reader');
  });
});
