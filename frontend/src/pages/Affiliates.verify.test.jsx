// Task 20261007-email-verification: Affiliates 403 state shows the verify prompt only when unverified.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';

const mockAuth = { user: { user_id: 'u1' } };
vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => mockAuth }));
vi.mock('../components/AppNav.jsx', () => ({ default: () => null }));
vi.mock('../components/AppBloom.jsx', () => ({ default: () => null }));
vi.mock('../components/Seo.jsx', () => ({ default: () => null }));
vi.mock('../hooks/useWarmCanvas.js', () => ({ useWarmCanvas: () => {} }));
vi.mock('../lib/affiliatesApi.js', async () => {
  const actual = await vi.importActual('../lib/affiliatesApi.js');
  return { ...actual, getAffiliateOverview: vi.fn(), getAffiliateResources: vi.fn(), fetchAffiliateFile: vi.fn() };
});
vi.mock('../lib/emailVerificationApi.js', () => ({ getEmailStatus: vi.fn(), resendVerification: vi.fn() }));
import { getAffiliateOverview, getAffiliateResources, AffiliatesApiError } from '../lib/affiliatesApi.js';
import { getEmailStatus } from '../lib/emailVerificationApi.js';
import Affiliates from './Affiliates.jsx';

function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/affiliates']}>
      <Routes><Route path="/affiliates" element={<Affiliates />} /></Routes>
    </MemoryRouter>,
  );
}
beforeEach(() => {
  mockAuth.user = { user_id: 'u1' };
  getAffiliateOverview.mockReset(); getAffiliateResources.mockReset(); getEmailStatus.mockReset();
  getAffiliateOverview.mockRejectedValue(new AffiliatesApiError('x', 403));
});
afterEach(() => cleanup());

describe('Affiliates verify-your-email state', () => {
  test('403 + unverified shows the verify prompt with resend', async () => {
    getEmailStatus.mockResolvedValue({ enabled: true, verified: false });
    renderPage();
    expect(await screen.findByText("This account isn't set up as a creator.")).toBeInTheDocument();
    expect(await screen.findByText('Verify your email to use the creator program')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Resend verification email/ })).toBeInTheDocument();
  });

  test.each([
    ['flag off', { enabled: false, verified: false }],
    ['verified (genuine non-creator)', { enabled: true, verified: true }],
  ])('403 + %s shows no verify prompt', async (_n, st) => {
    getEmailStatus.mockResolvedValue(st);
    renderPage();
    await screen.findByText("This account isn't set up as a creator.");
    await vi.waitFor(() => expect(getEmailStatus).toHaveBeenCalled());
    await new Promise((r) => setTimeout(r, 20));
    expect(screen.queryByTestId('email-verify-notice')).toBeNull();
  });

  test('403 + status check failing shows only the neutral non-creator state', async () => {
    getEmailStatus.mockRejectedValue(new Error('x'));
    renderPage();
    await screen.findByText("This account isn't set up as a creator.");
    await new Promise((r) => setTimeout(r, 20));
    expect(screen.queryByTestId('email-verify-notice')).toBeNull();
  });

  test('successful overview (verified creator) never asks for email status', async () => {
    getAffiliateOverview.mockReset();
    getAffiliateOverview.mockResolvedValue({
      v: 1, codes: [], metrics: { active_paying_subscribers: 0, monthly_earnings_cents: 0, commission_rate: 0.2 },
      series: { day: [], week: [], month: [] }, milestones: [],
    });
    getAffiliateResources.mockResolvedValue({ sections: {} });
    renderPage();
    await new Promise((r) => setTimeout(r, 50));
    expect(getEmailStatus).not.toHaveBeenCalled();
    expect(screen.queryByTestId('email-verify-notice')).toBeNull();
  });
});
