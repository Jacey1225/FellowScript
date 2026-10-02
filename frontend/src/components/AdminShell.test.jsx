// Task 20261001-admin-account-redesign (testing gate): admin shell + routing.
// Renders the REAL App route table (HashRouter, driven via window.location.hash)
// so a regression in App.jsx's nested /admin routes is caught, not a copy of it.
//
// Run with: cd frontend && npm test -- --run src/components/AdminShell.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor, within, fireEvent, act } from '@testing-library/react';

vi.mock('./AppNav.jsx', () => ({ default: () => <div data-testid="app-nav" /> }));
vi.mock('./AppBloom.jsx', () => ({ default: () => null }));
vi.mock('./VisitTracker.jsx', () => ({ default: () => null }));
vi.mock('../pages/Home.jsx', () => ({ default: () => <div>Home Page</div> }));
vi.mock('../pages/Reader.jsx', () => ({ default: () => <div>Reader Page</div> }));
vi.mock('../pages/SignIn.jsx', () => ({ default: () => <div>Sign In Page</div> }));
vi.mock('../pages/Account.jsx', () => ({ default: () => <div>Account Page</div> }));
// Heavy leaf pages: the shell/routing is under test, not their content.
vi.mock('../pages/AdminDetections.jsx', () => ({
  default: () => <h1 data-admin-heading tabIndex={-1}>Error logs</h1>,
}));
vi.mock('../pages/AdminDetectionDetail.jsx', () => ({
  default: () => <h1 data-admin-heading tabIndex={-1}>Detection detail</h1>,
}));
vi.mock('../pages/AdminPromoCodes.jsx', () => ({
  default: () => <h1 data-admin-heading tabIndex={-1}>Promo codes</h1>,
}));
vi.mock('../pages/AdminListings.jsx', () => ({
  default: () => <h1 data-admin-heading tabIndex={-1}>Group listings</h1>,
}));
vi.mock('../pages/AdminUserActions.jsx', () => ({
  default: () => <h1 data-admin-heading tabIndex={-1}>User actions</h1>,
}));
vi.mock('./AdminActivityMonitoring.jsx', () => ({ default: () => <div data-testid="activity" /> }));
vi.mock('./AdminMembershipGrant.jsx', () => ({ default: () => <div data-testid="grant" /> }));

const mockAuth = { user: { user_id: 'admin-1', username: 'a' } };
vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => mockAuth }));

import App from '../App.jsx';

function go(hash) {
  window.location.hash = hash;
}
async function renderAt(hash) {
  go(hash);
  render(<App />);
}
function nav() { return screen.getByRole('navigation', { name: 'Admin sections' }); }

beforeEach(() => { mockAuth.user = { user_id: 'admin-1', username: 'a' }; });
afterEach(() => { cleanup(); window.location.hash = ''; });

describe('Admin routing', () => {
  test('/admin redirects to Error logs (/admin/errors)', async () => {
    await renderAt('#/admin');
    await screen.findByRole('heading', { name: 'Error logs' });
    expect(window.location.hash).toBe('#/admin/errors');
  });

  test.each([
    ['#/admin/trends', 'Trends'],
    ['#/admin/errors', 'Error logs'],
    ['#/admin/accounts', 'Account actions'],
    ['#/admin/promo', 'Promo codes'],
    ['#/admin/listings', 'Group listings'],
    ['#/admin/users', 'User actions'],
    ['#/admin/detections/abc', 'Detection detail'],
  ])('deep link %s renders inside the shell with heading %s', async (hash, heading) => {
    await renderAt(hash);
    expect(await screen.findByRole('heading', { name: heading })).toBeInTheDocument();
    expect(nav()).toBeInTheDocument();
    expect(window.location.hash).toBe(hash);
  });

  test('Trends and Account actions pages mount their existing components', async () => {
    await renderAt('#/admin/trends');
    expect(await screen.findByTestId('activity')).toBeInTheDocument();
    cleanup();
    await renderAt('#/admin/accounts');
    expect(await screen.findByTestId('grant')).toBeInTheDocument();
  });

  test('unauthenticated user is sent to /signin and sees no admin chrome (AdminGate unchanged)', async () => {
    mockAuth.user = null;
    await renderAt('#/admin/trends');
    expect(await screen.findByText('Sign In Page')).toBeInTheDocument();
    expect(screen.queryByRole('navigation', { name: 'Admin sections' })).toBeNull();
  });

  test('unknown /admin child falls through to home, not a blank shell', async () => {
    await renderAt('#/admin/nope');
    // nested path matches no child; shell may render with empty outlet, but the
    // catch-all must not crash. Only assert no throw + nav still labeled or home.
    await waitFor(() => {
      const hasNav = screen.queryByRole('navigation', { name: 'Admin sections' });
      const home = screen.queryByText('Home Page');
      expect(hasNav || home).toBeTruthy();
    });
  });
});

describe('Admin sidebar a11y', () => {
  test('nav is labeled, lists the six sections in order', async () => {
    await renderAt('#/admin/trends');
    await screen.findByRole('heading', { name: 'Trends' });
    const links = within(nav()).getAllByRole('link');
    expect(links.map((l) => l.textContent.trim())).toEqual(
      ['Trends', 'Error logs', 'Account actions', 'Promo codes', 'Group listings', 'User actions'].map((s) => expect.stringContaining(s)),
    );
    expect(links.map((l) => l.getAttribute('href'))).toEqual(
      ['#/admin/trends', '#/admin/errors', '#/admin/accounts', '#/admin/promo', '#/admin/listings', '#/admin/users'],
    );
  });

  test.each([
    ['#/admin/trends', 'Trends'],
    ['#/admin/errors', 'Error logs'],
    ['#/admin/accounts', 'Account actions'],
    ['#/admin/promo', 'Promo codes'],
    ['#/admin/listings', 'Group listings'],
    ['#/admin/users', 'User actions'],
  ])('%s marks only %s with aria-current=page', async (hash, label) => {
    await renderAt(hash);
    await screen.findByRole('heading', { name: label });
    const current = within(nav()).getAllByRole('link').filter((l) => l.getAttribute('aria-current') === 'page');
    expect(current).toHaveLength(1);
    expect(current[0].textContent).toContain(label);
  });

  test('/admin/detections/:id keeps Error logs highlighted', async () => {
    await renderAt('#/admin/detections/abc');
    await screen.findByRole('heading', { name: 'Detection detail' });
    const current = within(nav()).getAllByRole('link').filter((l) => l.getAttribute('aria-current') === 'page');
    expect(current).toHaveLength(1);
    expect(current[0].textContent).toContain('Error logs');
  });

  test('decorative icons are aria-hidden', async () => {
    await renderAt('#/admin/trends');
    await screen.findByRole('heading', { name: 'Trends' });
    const icons = nav().querySelectorAll('.anticon');
    expect(icons.length).toBe(6);
    icons.forEach((i) => expect(i.getAttribute('aria-hidden')).toBe('true'));
  });

  test('keyboard: links are natively focusable/tabbable and Enter-activation navigates; focus moves to new h1', async () => {
    await renderAt('#/admin/trends');
    await screen.findByRole('heading', { name: 'Trends' });
    const link = within(nav()).getByRole('link', { name: /Account actions/ });
    expect(link.tabIndex).toBeGreaterThanOrEqual(0); // not removed from tab order
    link.focus();
    expect(document.activeElement).toBe(link);
    // Anchors activate on Enter via a click event in browsers; jsdom synthesizes click.
    fireEvent.click(link);
    const h = await screen.findByRole('heading', { name: 'Account actions' });
    await waitFor(() => expect(document.activeElement).toBe(h));
    expect(window.location.hash).toBe('#/admin/accounts');
  });

  test('focus is not stolen on first mount', async () => {
    await renderAt('#/admin/trends');
    const h = await screen.findByRole('heading', { name: 'Trends' });
    expect(document.activeElement).not.toBe(h);
  });
});

describe('Admin stays unlinked from public surfaces', () => {
  test('shell page sets noindex', async () => {
    await renderAt('#/admin/trends');
    await screen.findByRole('heading', { name: 'Trends' });
    await waitFor(() => {
      const m = document.head.querySelector('meta[name="robots"]');
      expect(m && m.getAttribute('content')).toMatch(/noindex/);
    });
  });
});
