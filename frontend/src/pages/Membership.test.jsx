// Task 20261118-public-membership-page testing: /membership is public (no
// download gate), signed-out visitors stash seats and go to sign-in, signed-in
// users get the existing SubscriptionCard and the pending purchase is consumed.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom';
import Membership from './Membership.jsx';
import { getPendingPurchase, setPendingPurchase } from '../lib/pendingPurchase.js';

vi.mock('../components/AppBloom.jsx', () => ({ default: () => null }));
vi.mock('../components/Seo.jsx', () => ({ default: () => null }));
vi.mock('../hooks/useWarmCanvas.js', () => ({ useWarmCanvas: () => {} }));
vi.mock('../components/SubscriptionCard.jsx', () => ({
  default: (p) => <div data-testid="subscription-card" data-seats={p.initialSeats} data-user={p.userId} />,
}));
const mockUseAuth = vi.fn();
vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => mockUseAuth() }));

function Sign() { const l = useLocation(); return <div data-testid="signin">{JSON.stringify(l.state)}</div>; }
function renderAt(url) {
  return render(
    <MemoryRouter initialEntries={[url]}>
      <Routes>
        <Route path="/membership" element={<Membership />} />
        <Route path="/signin" element={<Sign />} />
        <Route path="/download" element={<div data-testid="download" />} />
      </Routes>
    </MemoryRouter>,
  );
}
beforeEach(() => { sessionStorage.clear(); mockUseAuth.mockReset(); });
afterEach(() => cleanup());

describe('Membership page', () => {
  test('signed out: renders public page, no download/reader link, no card', () => {
    mockUseAuth.mockReturnValue({ user: null });
    const { container } = renderAt('/membership?seats=3');
    expect(screen.getByText('FellowScript membership')).toBeTruthy();
    expect(screen.queryByTestId('download')).toBeNull();
    expect(screen.queryByTestId('subscription-card')).toBeNull();
    expect(container.innerHTML).not.toMatch(/#?\/(download|reader)/);
    expect(screen.getByText('$13.50', { exact: false })).toBeTruthy(); // 3 seats, 10% off
  });
  test('signed out: Sign in stores seats and goes to /signin', () => {
    mockUseAuth.mockReturnValue({ user: null });
    renderAt('/membership?seats=3');
    fireEvent.click(screen.getByText('Sign in to continue'));
    expect(screen.getByTestId('signin')).toBeTruthy();
    expect(getPendingPurchase()).toEqual({ seats: 3 });
  });
  test('signed out: create account passes signup tab', () => {
    mockUseAuth.mockReturnValue({ user: null });
    renderAt('/membership?seats=2');
    fireEvent.click(screen.getByText('New here? Create an account'));
    expect(screen.getByTestId('signin').textContent).toContain('signup');
    expect(getPendingPurchase()).toEqual({ seats: 2 });
  });
  test('out-of-range seats param is clamped', () => {
    mockUseAuth.mockReturnValue({ user: null });
    renderAt('/membership?seats=9999');
    fireEvent.click(screen.getByText('Sign in to continue'));
    expect(getPendingPurchase()).toEqual({ seats: 100 });
  });
  test('signed in: shows SubscriptionCard with seats, consumes pending purchase, no auto-checkout', () => {
    setPendingPurchase(4);
    const f = vi.fn(); vi.stubGlobal('fetch', f);
    mockUseAuth.mockReturnValue({ user: { user_id: 'u1' } });
    renderAt('/membership?seats=4');
    const card = screen.getByTestId('subscription-card');
    expect(card.dataset.seats).toBe('4');
    expect(card.dataset.user).toBe('u1');
    expect(getPendingPurchase()).toBeNull();
    expect(f).not.toHaveBeenCalled();
    vi.unstubAllGlobals();
  });
});
