// Task 20260930-subscription-seat-invites testing: invite section visibility + owner review.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react';

const sectionProps = vi.fn();
vi.mock('./InviteLinkSection.jsx', () => ({
  default: (p) => { sectionProps(p); return <div data-testid="invite-section" />; },
}));
import SubscriptionCard from './SubscriptionCard.jsx';

const ME = 'owner-1';
const PLAN = { id: 'sub-1', user_id: ME, plan_type: 'group', status: 'active', is_trial: false, price_cents: 1215, max_members: 3 };
const res = (body, ok = true, status = ok ? 200 : 500) => ({ ok, status, json: async () => body });

function queueLoad(plan, requests = []) {
  global.fetch
    .mockResolvedValueOnce(res(plan))
    .mockResolvedValueOnce(res([]))
    .mockResolvedValueOnce(res(requests))
    .mockResolvedValueOnce(res([]))
    .mockResolvedValueOnce(res([]));
}
beforeEach(() => { global.fetch = vi.fn(); sectionProps.mockClear(); });
afterEach(cleanup);

describe('SubscriptionCard invite link', () => {
  test('owner of a multi-seat group plan gets the subscription invite section', async () => {
    queueLoad(PLAN);
    render(<SubscriptionCard userId={ME} />);
    expect(await screen.findByTestId('invite-section')).toBeInTheDocument();
    expect(sectionProps).toHaveBeenCalledWith(expect.objectContaining({ kind: 'subscription', userId: ME, subscriptionId: 'sub-1' }));
  });

  test('a plan member (not the owner) never sees it', async () => {
    queueLoad({ ...PLAN, user_id: 'someone-else' });
    render(<SubscriptionCard userId={ME} />);
    await screen.findByRole('button', { name: /Leave Plan/ });
    expect(screen.queryByTestId('invite-section')).toBeNull();
  });

  test('single-seat plan and non-group plan never see it', async () => {
    queueLoad({ ...PLAN, max_members: 1 });
    const { unmount } = render(<SubscriptionCard userId={ME} />);
    await screen.findByRole('button', { name: /Cancel Plan/ });
    expect(screen.queryByTestId('invite-section')).toBeNull();
    unmount();
    queueLoad({ ...PLAN, plan_type: 'individual' });
    render(<SubscriptionCard userId={ME} />);
    await screen.findByRole('button', { name: /Cancel Plan/ });
    expect(screen.queryByTestId('invite-section')).toBeNull();
  });

  test('Refresh join requests refetches only the requests list', async () => {
    queueLoad(PLAN);
    render(<SubscriptionCard userId={ME} />);
    const btn = await screen.findByRole('button', { name: /Refresh join requests/ });
    global.fetch.mockResolvedValueOnce(res([{ user_id: 'r1', username: 'newbie' }]));
    fireEvent.click(btn);
    await waitFor(() => expect(screen.getByText('newbie')).toBeInTheDocument());
    const last = global.fetch.mock.calls.at(-1)[0];
    expect(last).toMatch(/\/subscriptions\/sub-1\/requests$/);
    expect(screen.getByTestId('invite-section')).toBeInTheDocument();
  });

  test('accept failure (plan full) surfaces the server detail; decline removes the row', async () => {
    queueLoad(PLAN, [{ user_id: 'r1', username: 'pat' }, { user_id: 'r2', username: 'lee' }]);
    render(<SubscriptionCard userId={ME} />);
    await screen.findByText('pat');
    global.fetch.mockResolvedValueOnce(res({ detail: 'Plan is full' }, false, 409));
    fireEvent.click(screen.getAllByRole('button', { name: /Accept/ })[0]);
    expect(await screen.findByText('Plan is full')).toBeInTheDocument();
    expect(screen.getByText('pat')).toBeInTheDocument(); // request stays pending
    global.fetch.mockResolvedValueOnce(res({}, true, 204));
    const declineBtns = screen.getAllByRole('button').filter((b) => b.querySelector('[aria-label="close"]'));
    fireEvent.click(declineBtns[1]);
    await waitFor(() => expect(screen.queryByText('lee')).toBeNull());
    expect(global.fetch.mock.calls.at(-1)[0]).toMatch(/requests\/r2$/);
    expect(global.fetch.mock.calls.at(-1)[1].method).toBe('DELETE');
  });
});
