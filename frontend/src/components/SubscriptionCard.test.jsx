// Regression tests for task 20260904-compliance-reliability-bugs's fix to
// SubscriptionCard.jsx's cancelPlan(): a DELETE that merely didn't throw used
// to be treated as a successful cancellation regardless of its response
// status, so a failed Stripe-side cancellation would still flash "Plan
// canceled." This proves cancelPlan now checks res.ok/204 before flashing
// success, surfaces an error on a non-ok response or thrown exception
// instead, and always resyncs from the server afterward either way
// (Architecture Q27 -- the payments-adjacent fix security step 2 reviewed).
//
// Run with: cd frontend && npm test -- --run src/components/SubscriptionCard.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react';
import SubscriptionCard from './SubscriptionCard.jsx';

afterEach(() => cleanup());

const USER_ID = 'user-1';

const HOST_GROUP_PLAN = {
  id: 'sub-1',
  user_id: USER_ID,
  plan_type: 'group',
  status: 'active',
  is_trial: false,
  price_cents: 2699,
  max_members: 3,
  next_billing_date: null,
  card_brand: null,
  card_last4: null,
};

function jsonRes(body, ok = true, status = ok ? 200 : 500) {
  return { ok, status, json: async () => body };
}

// Mocks the 5 fetches SubscriptionCard's own load() makes, in the order it
// makes them, for a user who is the host of an active group plan with no
// members/requests/joinable plans -- enough to render the "Cancel Plan"
// control without any of that unrelated detail mattering to this fix.
function queueLoadSequence(fetchMock, plan) {
  fetchMock
    .mockResolvedValueOnce(jsonRes(plan || {}, !!plan, plan ? 200 : 404)) // GET /subscriptions/user/:id
    .mockResolvedValueOnce(jsonRes([]))                                   // GET /subscriptions/:id/members
    .mockResolvedValueOnce(jsonRes([]))                                   // GET /subscriptions/:id/requests
    .mockResolvedValueOnce(jsonRes([]))                                   // GET /subscriptions/user/:id/requests
    .mockResolvedValueOnce(jsonRes([]));                                  // GET /friends/:id
}

async function renderAndOpenConfirm() {
  render(<SubscriptionCard userId={USER_ID} />);
  // Regex (not an exact string) because the trigger Button's accessible name
  // also includes its DeleteOutlined icon's aria-label ("delete Cancel Plan").
  const cancelBtn = await screen.findByRole('button', { name: /Cancel Plan/ });
  fireEvent.click(cancelBtn);
  const confirmBtn = await screen.findByRole('button', { name: 'Cancel plan' });
  return confirmBtn;
}

beforeEach(() => {
  global.fetch = vi.fn();
});

describe('cancelPlan — never assumes success from a fetch that merely did not throw', () => {
  test('a successful DELETE (204) flashes "Plan canceled." and resyncs to the free plan', async () => {
    queueLoadSequence(global.fetch, HOST_GROUP_PLAN);
    const confirmBtn = await renderAndOpenConfirm();

    // The DELETE call itself, then the unconditional resync load() -- now
    // reporting no plan (free tier), matching what a real successful
    // server-side cancellation would leave behind.
    global.fetch.mockResolvedValueOnce({ ok: true, status: 204, json: async () => ({}) });
    queueLoadSequence(global.fetch, null);

    fireEvent.click(confirmBtn);

    await waitFor(() => expect(screen.getByText('Plan canceled.')).toBeTruthy());
    expect(screen.queryByText(/Could not cancel plan/)).toBeNull();
  });

  test('a non-ok DELETE response (e.g. Stripe-side cancellation failure) surfaces the server error, not "Plan canceled."', async () => {
    queueLoadSequence(global.fetch, HOST_GROUP_PLAN);
    const confirmBtn = await renderAndOpenConfirm();

    global.fetch.mockResolvedValueOnce(
      jsonRes({ detail: 'Could not confirm cancellation with Stripe. Please try again.' }, false, 502)
    );
    // The plan was never actually canceled server-side, so the resync load()
    // must still show the same active plan.
    queueLoadSequence(global.fetch, HOST_GROUP_PLAN);

    fireEvent.click(confirmBtn);

    await waitFor(() =>
      expect(screen.getByText('Could not confirm cancellation with Stripe. Please try again.')).toBeTruthy()
    );
    expect(screen.queryByText('Plan canceled.')).toBeNull();
    // The plan is still shown as active -- the UI did not drift to "free" on
    // a failed cancellation.
    expect(screen.getByText('Group Plan')).toBeTruthy();
  });

  test('a network-throwing DELETE surfaces a generic connection error, not "Plan canceled."', async () => {
    queueLoadSequence(global.fetch, HOST_GROUP_PLAN);
    const confirmBtn = await renderAndOpenConfirm();

    global.fetch.mockRejectedValueOnce(new Error('network down'));
    queueLoadSequence(global.fetch, HOST_GROUP_PLAN);

    fireEvent.click(confirmBtn);

    await waitFor(() => expect(screen.getByText('Could not reach the server.')).toBeTruthy());
    expect(screen.queryByText('Plan canceled.')).toBeNull();
  });
});
