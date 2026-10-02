import React from 'react';
import { describe, test, expect, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/react';
import { FreePlanLimits } from './SubscriptionCard.jsx';

afterEach(() => cleanup());

const USAGE = {
  subscribed: false, window_days: 7,
  resources: {
    notes: { unlimited: false, used: 2, limit: 5, remaining: 3 },
    agent_events: { unlimited: false, used: 0, limit: 1, remaining: 1 },
    sessions: { unlimited: false, used: 0, limit: 1, remaining: 1 },
    agent_notifications: { unlimited: false, used: 0, limit: 3, remaining: 3 },
  },
  paid_only: {
    session_summaries: { allowed: false, free_allowed: false },
    explorer_publish: { allowed: false, free_allowed: false },
  },
};

describe('FreePlanLimits', () => {
  test('lists every limit from the usage payload with no hardcoded numbers', () => {
    render(<FreePlanLimits usage={USAGE} />);
    const list = screen.getByTestId('free-plan-limits');
    expect(within(list).getByText('5 per week')).toBeInTheDocument();
    expect(within(list).getByText('1 in total')).toBeInTheDocument();
    expect(within(list).getByText('1 at a time')).toBeInTheDocument();
    expect(within(list).getByText('Join as many as you like')).toBeInTheDocument();
    expect(within(list).getAllByText('Subscribers only')).toHaveLength(2);
    expect(within(list).getByText('Browsing and joining stay free')).toBeInTheDocument();
  });

  test('follows a changed server value and window', () => {
    const u = { ...USAGE, window_days: 10, resources: { ...USAGE.resources, notes: { unlimited: false, used: 0, limit: 8 } } };
    render(<FreePlanLimits usage={u} />);
    expect(screen.getByText('8 every 10 days')).toBeInTheDocument();
  });

  test('paid-only row shows Included when the server says free is allowed', () => {
    const u = { ...USAGE, paid_only: { ...USAGE.paid_only, session_summaries: { allowed: true, free_allowed: true } } };
    render(<FreePlanLimits usage={u} />);
    expect(screen.getByText('Included')).toBeInTheDocument();
  });

  test('before usage loads shows a neutral loading caption, never a stale number', () => {
    render(<FreePlanLimits usage={null} />);
    expect(screen.getByText('Loading limits')).toBeInTheDocument();
    expect(screen.queryByText(/per week/)).toBeNull();
  });
});
