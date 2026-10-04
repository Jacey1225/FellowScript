// Task 20261004-web-friend-invite-rewards testing: web reward notice.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor, fireEvent } from '@testing-library/react';

vi.mock('../lib/ownerRewardsApi.js', async () => {
  const actual = await vi.importActual('../lib/ownerRewardsApi.js');
  return { ...actual, fetchRewardSummary: vi.fn() };
});
import { fetchRewardSummary, OwnerRewardsApiError } from '../lib/ownerRewardsApi.js';
import RewardNotice, { rewardNoticeText } from './RewardNotice.jsx';

beforeEach(() => { fetchRewardSummary.mockReset(); sessionStorage.clear(); });
afterEach(() => cleanup());

describe('RewardNotice', () => {
  test('stripe inviter: auto-applies copy, no claim instruction', async () => {
    fetchRewardSummary.mockResolvedValue({ earned: 1, percent_off: 50, provider: 'stripe' });
    render(<RewardNotice userId="u1" />);
    const n = await screen.findByTestId('reward-notice');
    expect(n.textContent).toContain('You earned 50% off your next month');
    expect(n.textContent).toContain('next invoice automatically');
    expect(n.textContent).not.toContain('Claim reward');
  });

  test('apple inviter: tells user to open iOS app and tap Claim reward', async () => {
    fetchRewardSummary.mockResolvedValue({ earned: 1, percent_off: 50, provider: 'apple', can_claim_apple: true });
    render(<RewardNotice userId="u1" />);
    const n = await screen.findByTestId('reward-notice');
    expect(n.textContent).toContain('iPhone app');
    expect(n.textContent).toContain('Claim reward');
  });

  test('unknown provider falls back to neutral copy', () => {
    expect(rewardNoticeText({ provider: null })).toContain('individual plan');
  });

  test.each([0, undefined])('nothing when earned=%s', async (earned) => {
    fetchRewardSummary.mockResolvedValue({ earned, percent_off: 50, provider: 'stripe' });
    render(<RewardNotice userId="u1" />);
    await waitFor(() => expect(fetchRewardSummary).toHaveBeenCalled());
    expect(screen.queryByTestId('reward-notice')).toBeNull();
  });

  test.each([404, 500])('nothing on error %s', async (status) => {
    fetchRewardSummary.mockRejectedValue(new OwnerRewardsApiError('x', status));
    render(<RewardNotice userId="u1" />);
    await waitFor(() => expect(fetchRewardSummary).toHaveBeenCalled());
    expect(screen.queryByTestId('reward-notice')).toBeNull();
  });

  test('uses provided summary without fetching; null summary renders nothing', () => {
    const { rerender } = render(<RewardNotice userId="u1" summary={{ earned: 2, percent_off: 50, provider: 'stripe' }} />);
    expect(screen.getByTestId('reward-notice')).toBeTruthy();
    expect(fetchRewardSummary).not.toHaveBeenCalled();
    rerender(<RewardNotice userId="u1" summary={null} />);
    expect(screen.queryByTestId('reward-notice')).toBeNull();
  });

  test('dismiss hides, persists for same earned count, re-shows when count changes', async () => {
    const s = { earned: 1, percent_off: 50, provider: 'stripe' };
    const { unmount } = render(<RewardNotice userId="u1" summary={s} />);
    fireEvent.click(screen.getByText('Dismiss'));
    expect(screen.queryByTestId('reward-notice')).toBeNull();
    unmount();
    render(<RewardNotice userId="u1" summary={s} />);
    expect(screen.queryByTestId('reward-notice')).toBeNull();
    cleanup();
    render(<RewardNotice userId="u1" summary={{ ...s, earned: 2 }} />);
    expect(screen.getByTestId('reward-notice')).toBeTruthy();
  });
});
