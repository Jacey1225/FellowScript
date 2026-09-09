// Route-level SEO wiring sweep (task 20260909-website-seo): confirms every
// route App.jsx mounts gets a real, distinct <title> and the correct
// index/noindex posture -- the exact regression the acceptance criteria
// calls out ("no previously-hidden surface becomes newly discoverable" /
// "tab titles/UX aren't collateral damage of an SEO-only fix").
//
// Reader.jsx is checked at the source level in the trailing describe block
// instead of fully mounted here -- it pulls in dockview/ResizeObserver
// machinery unrelated to this task, matching this codebase's existing
// source-guard-test precedent for exactly that situation
// (Reader.dockview.test.jsx's reader-dock.css check).
//
// Run with: cd frontend && npm test -- --run src/App.route-seo.test.jsx
import React from 'react';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import Privacy from './pages/Privacy.jsx';
import Terms from './pages/Terms.jsx';
import SignIn from './pages/SignIn.jsx';
import ForgotPassword from './pages/ForgotPassword.jsx';
import ResetPassword from './pages/ResetPassword.jsx';
import VerifyMfa from './pages/VerifyMfa.jsx';
import Account from './pages/Account.jsx';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Account.jsx pulls in a lot of unrelated UI -- stub it out exactly as the
// existing Account.*.test.jsx files do, since only the <Seo> wiring matters
// here.
vi.mock('./components/AppNav.jsx', () => ({ default: () => <div data-testid="app-nav" /> }));
vi.mock('./components/AppBloom.jsx', () => ({ default: () => null }));
vi.mock('./components/SubscriptionCard.jsx', () => ({ default: () => <div data-testid="subscription-card" /> }));
vi.mock('./components/DonationButton.jsx', () => ({ default: () => null }));

const mockUseAuth = vi.fn();
vi.mock('./context/AuthContext.jsx', () => ({
  useAuth: () => mockUseAuth(),
}));

function jsonRes(body, ok = true, status = ok ? 200 : 500) {
  return { ok, status, json: async () => body };
}

function robotsMetaEl() {
  return document.head.querySelector('meta[name="robots"]');
}

// react-helmet-async commits to the real document head via
// requestAnimationFrame by default, not synchronously within render().
async function waitForRobotsMeta() {
  await waitFor(() => expect(robotsMetaEl()).not.toBeNull());
  return robotsMetaEl().getAttribute('content');
}

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe('App routes — head-tag index/noindex posture (task 20260909-website-seo)', () => {
  test('Privacy: distinct title, indexable (listed in sitemap.xml)', async () => {
    render(<MemoryRouter initialEntries={['/privacy']}><Privacy /></MemoryRouter>);

    expect(await waitForRobotsMeta()).toBe('index, follow');
    expect(document.title).toBe('Privacy Policy — FellowScript');
  });

  test('Terms: distinct title, indexable (listed in sitemap.xml)', async () => {
    render(<MemoryRouter initialEntries={['/terms']}><Terms /></MemoryRouter>);

    expect(await waitForRobotsMeta()).toBe('index, follow');
    expect(document.title).toBe('Terms of Service — FellowScript');
  });

  test('SignIn: distinct tab title, but noindex (authenticated flow, not a marketing page)', async () => {
    mockUseAuth.mockReturnValue({ signIn: vi.fn() });
    render(<MemoryRouter initialEntries={['/signin']}><SignIn /></MemoryRouter>);

    expect(await waitForRobotsMeta()).toBe('noindex, nofollow');
    expect(document.title).toBe('Sign In — FellowScript');
  });

  test('ForgotPassword: distinct tab title, but noindex', async () => {
    render(<MemoryRouter initialEntries={['/forgot-password']}><ForgotPassword /></MemoryRouter>);

    expect(await waitForRobotsMeta()).toBe('noindex, nofollow');
    expect(document.title).toBe('Forgot Password — FellowScript');
  });

  test('ResetPassword (no token): distinct tab title, but noindex', async () => {
    render(<MemoryRouter initialEntries={['/reset-password']}><ResetPassword /></MemoryRouter>);

    expect(await waitForRobotsMeta()).toBe('noindex, nofollow');
    expect(document.title).toBe('Reset Password — FellowScript');
  });

  test('ResetPassword (with token): still noindex once the real form renders', async () => {
    render(<MemoryRouter initialEntries={['/reset-password?token=abc']}><ResetPassword /></MemoryRouter>);

    expect(await waitForRobotsMeta()).toBe('noindex, nofollow');
    expect(document.title).toBe('Reset Password — FellowScript');
  });

  test('VerifyMfa (no sign-in in progress): distinct tab title, but noindex', async () => {
    mockUseAuth.mockReturnValue({ signIn: vi.fn() });
    render(<MemoryRouter initialEntries={['/verify-2fa']}><VerifyMfa /></MemoryRouter>);

    expect(await waitForRobotsMeta()).toBe('noindex, nofollow');
    expect(document.title).toBe('Verify Sign-In — FellowScript');
  });

  test('Account: distinct tab title, but noindex', async () => {
    global.fetch = vi.fn(async () => jsonRes({}, false, 404));
    mockUseAuth.mockReturnValue({
      user: { user_id: 'user-1', username: 'tester' },
      signOut: vi.fn(),
      updateUser: vi.fn(),
    });
    render(<MemoryRouter initialEntries={['/account']}><Account /></MemoryRouter>);
    await screen.findByTestId('app-nav');

    expect(await waitForRobotsMeta()).toBe('noindex, nofollow');
    expect(document.title).toBe('Account — FellowScript');
  });
});

describe('Reader.jsx — Seo wiring (source-level check, matching the reader-dock.css source-guard precedent)', () => {
  test('declares a real tab title for "/reader" and is explicitly noindex', () => {
    const src = fs.readFileSync(path.join(__dirname, 'pages/Reader.jsx'), 'utf8');
    const match = src.match(/<Seo\s+([\s\S]*?)\/>/);
    expect(match).toBeTruthy();

    const block = match[1];
    expect(block).toMatch(/title="Reader — FellowScript"/);
    expect(block).toMatch(/path="\/reader"/);
    expect(block).toMatch(/\bnoindex\b/);
  });
});

describe('App.jsx — HashRouter crawlability decision is documented inline (acceptance criteria: "not silently left unresolved")', () => {
  test('a Decision comment naming HashRouter sits directly above the HashRouter usage', () => {
    const src = fs.readFileSync(path.join(__dirname, 'App.jsx'), 'utf8');
    const hashRouterIdx = src.indexOf('<HashRouter>');
    expect(hashRouterIdx).toBeGreaterThan(-1);

    const preceding = src.slice(Math.max(0, hashRouterIdx - 1500), hashRouterIdx);
    expect(preceding).toMatch(/Decision/);
    expect(preceding).toMatch(/HashRouter/);
  });
});
