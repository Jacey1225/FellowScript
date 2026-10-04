// Task 20261001-promo-owner-rewards testing: /invite page.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor } from '@testing-library/react';
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom';

const mockAuth = { user: { user_id: 'u1' } };
vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => mockAuth }));
vi.mock('../components/AppNav.jsx', () => ({ default: () => null }));
vi.mock('../components/Seo.jsx', () => ({ default: () => null }));
vi.mock('../components/FriendInviteCode.jsx', () => ({ default: ({ userId }) => <div data-testid="fic">{userId}</div> }));
vi.mock('../lib/ownerRewardsApi.js', async () => {
  const actual = await vi.importActual('../lib/ownerRewardsApi.js');
  return { ...actual, fetchRewardSummary: vi.fn() };
});
import { fetchRewardSummary, OwnerRewardsApiError } from '../lib/ownerRewardsApi.js';
import InviteFriends from './InviteFriends.jsx';

function Where() { const l = useLocation(); return <div data-testid="where">{l.pathname}</div>; }
function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/invite']}>
      <Routes>
        <Route path="/invite" element={<InviteFriends />} />
        <Route path="*" element={<Where />} />
      </Routes>
    </MemoryRouter>,
  );
}
beforeEach(() => { mockAuth.user = { user_id: 'u1' }; fetchRewardSummary.mockReset(); });
afterEach(() => cleanup());

describe('InviteFriends', () => {
  test('signed out redirects to signin and fetches nothing', async () => {
    mockAuth.user = null;
    renderPage();
    await waitFor(() => expect(screen.getByTestId('where').textContent).toBe('/signin'));
    expect(fetchRewardSummary).not.toHaveBeenCalled();
  });

  test('renders invite code component for the user; reward summary hidden on 404', async () => {
    fetchRewardSummary.mockRejectedValue(new OwnerRewardsApiError('nf', 404));
    renderPage();
    expect(screen.getByTestId('fic').textContent).toBe('u1');
    await waitFor(() => expect(fetchRewardSummary).toHaveBeenCalledWith('u1'));
    expect(screen.queryByTestId('reward-summary')).toBeNull();
  });

  test('hidden on any other failure too', async () => {
    fetchRewardSummary.mockRejectedValue(new OwnerRewardsApiError('x', 500));
    renderPage();
    await waitFor(() => expect(fetchRewardSummary).toHaveBeenCalled());
    expect(screen.queryByTestId('reward-summary')).toBeNull();
  });

  test('apple owner with earned reward is pointed to the iPhone app, with iOS limitation note', async () => {
    fetchRewardSummary.mockResolvedValue({ percent_off: 50, earned: 2, claimed: 1, provider: 'apple' });
    renderPage();
    const box = await screen.findByTestId('reward-summary');
    expect(box.textContent).toMatch(/50% off/);
    expect(box.textContent).toMatch(/2 earned, 1 used/);
    expect(box.textContent).toMatch(/iPhone app/);
    expect(box.textContent).toMatch(/can't use a code there/);
  });

  test('stripe owner told rewards apply automatically', async () => {
    fetchRewardSummary.mockResolvedValue({ percent_off: 50, earned: 0, claimed: 0, provider: 'stripe' });
    renderPage();
    expect((await screen.findByTestId('reward-summary')).textContent).toMatch(/next invoice automatically/);
  });

  test('no provider: told rewards need an individual plan; no claim hint for apple', async () => {
    fetchRewardSummary.mockResolvedValue({ percent_off: 50, earned: 0, claimed: 0, provider: null });
    renderPage();
    const t = (await screen.findByTestId('reward-summary')).textContent;
    expect(t).toMatch(/individual plan/);
    expect(t).not.toMatch(/iPhone app under Account/);
  });
  test('reward notice shown when earned > 0 and absent when none (web notice)', async () => {
    fetchRewardSummary.mockResolvedValue({ percent_off: 50, earned: 1, claimed: 0, provider: 'apple' });
    renderPage();
    expect((await screen.findByTestId('reward-notice')).textContent).toMatch(/You earned 50% off your next month/);
    cleanup();
    sessionStorage.clear();
    fetchRewardSummary.mockResolvedValue({ percent_off: 50, earned: 0, claimed: 0, provider: 'apple' });
    renderPage();
    await screen.findByTestId('reward-summary');
    expect(screen.queryByTestId('reward-notice')).toBeNull();
  });
});
