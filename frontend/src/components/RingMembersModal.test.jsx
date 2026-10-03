// Task 20261003-web-reader-ios-parity step 2. Run: npm test -- --run src/components/RingMembersModal.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach, beforeEach } from 'vitest';
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react';
import RingMembersModal from './RingMembersModal.jsx';
import * as ringApi from '../lib/ringApi.js';

afterEach(() => cleanup());
beforeEach(() => vi.restoreAllMocks());

const USER = { user_id: 'me' };
const SESSION = { id: 's1', participants: ['me', 'joined'] };
const CANDS = [
  { user_id: 'a', username: 'Alice' },
  { user_id: 'b', username: 'Bob' },
  { user_id: 'joined', username: 'Jo' },
  { user_id: 'me', username: 'Me' },
];
const mount = (o = {}) => render(
  <RingMembersModal open onClose={vi.fn()} session={SESSION} user={USER} candidates={CANDS} sentRef={{ current: new Set() }} {...o} />,
);

describe('RingMembersModal', () => {
  test('splits not-yet-joined / already-in-call and excludes self', () => {
    mount();
    expect(screen.getByRole('checkbox', { name: 'Alice. Not selected' })).toBeInTheDocument();
    expect(screen.getByText('Already in call')).toBeInTheDocument();
    expect(screen.queryByRole('checkbox', { name: /^Me\./ })).toBeNull();
  });
  test('Ring is disabled until a member is selected and shows the count', () => {
    mount();
    expect(screen.getByRole('button', { name: 'Ring' })).toBeDisabled();
    fireEvent.click(screen.getByRole('checkbox', { name: /Alice/ }));
    fireEvent.click(screen.getByRole('checkbox', { name: /Bob/ }));
    expect(screen.getByRole('button', { name: 'Ring (2)' })).not.toBeDisabled();
  });
  test('per-row outcomes: sent, rate limited, error; rate limited rows can be retried', async () => {
    const spy = vi.spyOn(ringApi, 'ringMembers').mockResolvedValue({
      a: { sent: true, reason: null }, b: { sent: false, reason: 'rate_limited' },
    });
    mount();
    fireEvent.click(screen.getByRole('checkbox', { name: /Alice/ }));
    fireEvent.click(screen.getByRole('checkbox', { name: /Bob/ }));
    fireEvent.click(screen.getByRole('button', { name: 'Ring (2)' }));
    await waitFor(() => expect(screen.getByRole('checkbox', { name: 'Alice. Sent' })).toBeInTheDocument());
    expect(spy).toHaveBeenCalledWith('me', 's1', ['a', 'b']);
    expect(screen.getByRole('checkbox', { name: 'Bob. Rate limited' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Done' })).toBeInTheDocument();
    // sent rows are not interactive; rate limited rows go back to selected
    fireEvent.click(screen.getByRole('checkbox', { name: 'Alice. Sent' }));
    expect(screen.getByRole('checkbox', { name: 'Alice. Sent' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('checkbox', { name: 'Bob. Rate limited' }));
    expect(screen.getByRole('checkbox', { name: 'Bob. Selected' })).toBeInTheDocument();
  });
  test('request failure marks every target as an error with the message, retryable', async () => {
    vi.spyOn(ringApi, 'ringMembers').mockRejectedValue(new ringApi.RingError('Ringing is not available right now.', 404));
    mount();
    fireEvent.click(screen.getByRole('checkbox', { name: /Alice/ }));
    fireEvent.click(screen.getByRole('button', { name: 'Ring (1)' }));
    await waitFor(() => expect(screen.getByRole('checkbox', { name: 'Alice. Ringing is not available right now.' })).toBeInTheDocument());
  });
  test('a 429 shows as rate limited', async () => {
    vi.spyOn(ringApi, 'ringMembers').mockRejectedValue(new ringApi.RingError("Couldn't send", 429));
    mount();
    fireEvent.click(screen.getByRole('checkbox', { name: /Alice/ }));
    fireEvent.click(screen.getByRole('button', { name: 'Ring (1)' }));
    await waitFor(() => expect(screen.getByRole('checkbox', { name: 'Alice. Rate limited' })).toBeInTheDocument());
  });
  test('shows an empty state with no candidates', () => {
    mount({ candidates: [] });
    expect(screen.getByText('No other members to ring.')).toBeInTheDocument();
  });
  test('previously sent targets stay sent across reopening (sentRef)', () => {
    mount({ sentRef: { current: new Set(['a']) } });
    expect(screen.getByRole('checkbox', { name: 'Alice. Sent' })).toBeInTheDocument();
  });
});
