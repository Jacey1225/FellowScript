// Task 20261003-web-reader-ios-parity step 1: join-window gating, host-only
// Edit/Delete, delete confirmation. Run: npm test -- --run src/components/SessionWidget.parity.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach, beforeEach } from 'vitest';
import { render, screen, fireEvent, cleanup, act } from '@testing-library/react';
import { UpcomingCard } from './SessionWidget.jsx';

afterEach(() => { cleanup(); vi.useRealTimers(); });

const USER = { user_id: 'u1', username: 'me' };
const MIN = 60e3;

function session(over = {}) {
  return { id: 's1', title: 'Study', creator_id: 'u1', participants: [], time_end: '',
    time_start: new Date(Date.now() + 60 * MIN).toISOString(), ...over };
}
function renderCard(s, extra = {}) {
  const p = { onJoin: vi.fn(), onLeave: vi.fn(), onEdit: vi.fn(), onDelete: vi.fn(), onClearJoinError: vi.fn(), ...extra };
  render(<UpcomingCard session={s} user={USER} activeSessionId={null} {...p} />);
  return p;
}

describe('join window gating', () => {
  test('Join is disabled and announced as not open yet outside the window', () => {
    const p = renderCard(session());
    const btn = screen.getByRole('button', { name: 'Join Study, not open yet' });
    expect(btn).toBeDisabled();
    fireEvent.click(btn);
    expect(p.onJoin).not.toHaveBeenCalled();
  });
  test('Join is enabled inside the 10 minute grace', () => {
    const p = renderCard(session({ time_start: new Date(Date.now() + 9 * MIN).toISOString() }));
    fireEvent.click(screen.getByRole('button', { name: 'Join Study' }));
    expect(p.onJoin).toHaveBeenCalledWith('s1');
  });
  test('missing time_start fails closed', () => {
    renderCard(session({ time_start: '' }));
    expect(screen.getByRole('button', { name: /not open yet/ })).toBeDisabled();
  });
  test('re-evaluates live: enables itself when the window opens, no reload', () => {
    vi.useFakeTimers();
    renderCard(session({ time_start: new Date(Date.now() + 10 * MIN + 2000).toISOString() }));
    expect(screen.getByRole('button', { name: /not open yet/ })).toBeDisabled();
    act(() => { vi.advanceTimersByTime(3000); });
    expect(screen.getByRole('button', { name: 'Join Study' })).not.toBeDisabled();
  });
});

describe('host-only Edit and Delete', () => {
  test('hidden for a non-host', () => {
    renderCard(session({ creator_id: 'someone-else' }));
    expect(screen.queryByTitle('Edit session')).toBeNull();
    expect(screen.queryByTitle('Delete session')).toBeNull();
  });
  test('hidden when creator_id is empty (fail closed)', () => {
    renderCard(session({ creator_id: '' }));
    expect(screen.queryByTitle('Edit session')).toBeNull();
    expect(screen.queryByTitle('Delete session')).toBeNull();
  });
  test('host sees Edit and Delete', () => {
    const p = renderCard(session());
    fireEvent.click(screen.getByTitle('Edit session'));
    expect(p.onEdit).toHaveBeenCalled();
  });
});

describe('delete confirmation', () => {
  test('Delete asks first and only deletes on confirm', () => {
    const p = renderCard(session());
    fireEvent.click(screen.getByTitle('Delete session'));
    expect(screen.getByText('Delete Session?')).toBeInTheDocument();
    expect(p.onDelete).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }));
    expect(p.onDelete).toHaveBeenCalledWith('s1');
  });
  test('Cancel never deletes', () => {
    const p = renderCard(session());
    fireEvent.click(screen.getByTitle('Delete session'));
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(p.onDelete).not.toHaveBeenCalled();
  });
});
