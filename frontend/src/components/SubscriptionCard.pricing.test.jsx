// Web-only payments: exact seat price at any count, and desktop (Tauri) checkout
// opens in the system browser instead of navigating the app webview.
// Run: cd frontend && npm test -- --run src/components/SubscriptionCard.pricing.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react';
import SubscriptionCard from './SubscriptionCard.jsx';

afterEach(() => { cleanup(); delete window.__TAURI_INTERNALS__; vi.restoreAllMocks(); });
const USER = 'user-1';
const res = (status, body) => ({ ok: status >= 200 && status < 300, status, json: async () => body });

function mockApi() {
  global.fetch = vi.fn(async (url) => {
    const u = String(url);
    if (u.includes(`/subscriptions/user/${USER}/requests`)) return res(200, []);
    if (u.includes(`/subscriptions/user/${USER}`)) return res(404, {});
    if (u.includes('/friends/')) return res(200, []);
    if (u.endsWith('/subscriptions/checkout')) return res(200, { url: 'https://stripe.test/s' });
    return res(404, {});
  });
}

beforeEach(() => {
  const m = new Map();
  vi.stubGlobal('localStorage', {
    getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => { m.set(k, String(v)); },
    removeItem: (k) => { m.delete(k); }, clear: () => m.clear(),
  });
  delete window.location;
  window.location = { href: '', search: '', hash: '', pathname: '/' };
  mockApi();
});

describe('exact seat price', () => {
  test.each([[1, '$5.00'], [2, '$9.00'], [9, '$40.50'], [20, '$90.00']])('%i seats shows %s/mo', async (n, price) => {
    render(<SubscriptionCard userId={USER} />);
    const input = await screen.findByRole('spinbutton');
    fireEvent.change(input, { target: { value: String(n) } });
    await waitFor(() => expect(screen.getAllByText((_, el) => el.tagName === 'DIV' && el.textContent === `${price}/mo`).length).toBeGreaterThan(0));
    expect(document.body.textContent).not.toMatch(/Price shown at checkout|confirmed on the secure checkout/);
  });
});

describe('desktop checkout', () => {
  test('opens the system browser via window.open and does not navigate the webview', async () => {
    window.__TAURI_INTERNALS__ = {};
    const open = vi.spyOn(window, 'open').mockImplementation(() => null);
    render(<SubscriptionCard userId={USER} />);
    fireEvent.click(await screen.findByRole('button', { name: 'Subscribe on the website' }));
    await waitFor(() => expect(open).toHaveBeenCalledWith('https://stripe.test/s', '_blank', 'noopener,noreferrer'));
    expect(window.location.href).toBe('');
    expect(await screen.findByText(/Finish checkout in your browser/)).toBeTruthy();
  });

  test('web navigates the page to checkout', async () => {
    const open = vi.spyOn(window, 'open').mockImplementation(() => null);
    render(<SubscriptionCard userId={USER} />);
    fireEvent.click(await screen.findByRole('button', { name: 'Subscribe' }));
    await waitFor(() => expect(window.location.href).toBe('https://stripe.test/s'));
    expect(open).not.toHaveBeenCalled();
  });
});

describe('existing (legacy) subscriber seat editor', () => {
  const PLAN = { id: 'sub-1', user_id: USER, plan_type: 'group', provider: 'stripe', status: 'active',
    max_members: 2, price_cents: 810 };
  // Server quotes the legacy schedule for this plan (5 seats = 2025, not the formula's 2250).
  const LEGACY = { 3: 1215, 5: 2025 };

  function mockLegacy({ quoteOk = true } = {}) {
    global.fetch = vi.fn(async (url) => {
      const u = String(url);
      if (u.includes('/subscriptions/quote')) {
        const n = Number(new URL(u, 'http://x').searchParams.get('seats'));
        return quoteOk ? res(200, { seats: n, total_cents: LEGACY[n], legacy: true, blocked: false }) : res(500, {});
      }
      if (u.includes(`/subscriptions/user/${USER}/requests`)) return res(200, []);
      if (u.includes(`/subscriptions/user/${USER}`)) return res(200, PLAN);
      if (u.includes('/members') || u.includes('/requests')) return res(200, []);
      if (u.includes('/friends/')) return res(200, []);
      return res(404, {});
    });
  }

  test('shows the server quote (legacy 2025), not the formula (2250)', async () => {
    mockLegacy();
    render(<SubscriptionCard userId={USER} />);
    fireEvent.click(await screen.findByRole('button', { name: /Change \(2 members\)/ }));
    const input = await screen.findByRole('spinbutton');
    fireEvent.change(input, { target: { value: '5' } });
    await waitFor(() => expect(screen.getByText('$20.25/mo')).toBeTruthy());
    expect(document.body.textContent).not.toMatch(/\$22\.50/);
    expect(global.fetch.mock.calls.some(([u]) => String(u).includes('/subscriptions/quote?seats=5'))).toBe(true);
  });

  test('quote failure shows no price (never the formula)', async () => {
    mockLegacy({ quoteOk: false });
    render(<SubscriptionCard userId={USER} />);
    fireEvent.click(await screen.findByRole('button', { name: /Change \(2 members\)/ }));
    fireEvent.change(await screen.findByRole('spinbutton'), { target: { value: '5' } });
    await waitFor(() => expect(global.fetch.mock.calls.some(([u]) => String(u).includes('/subscriptions/quote'))).toBe(true));
    expect(document.body.textContent).not.toMatch(/\$22\.50|\$20\.25/);
  });
});
