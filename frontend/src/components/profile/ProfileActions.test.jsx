// Task 20261030-user-profiles testing step 8: relationship-driven actions.
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import ProfileActions from './ProfileActions.jsx';
import ProfileHeader from './ProfileHeader.jsx';

const prof = (state, extra = {}) => ({ username: 'Ann', relationship: { state }, ...extra });

afterEach(cleanup);

describe('ProfileActions', () => {
  test('none: Add friend calls onAdd', () => {
    const onAdd = vi.fn();
    render(<ProfileActions profile={prof('none')} onAdd={onAdd} />);
    fireEvent.click(screen.getByRole('button', { name: /add ann as a friend/i }));
    expect(onAdd).toHaveBeenCalledTimes(1);
  });

  test('request_sent: disabled "Request sent", no Add', () => {
    render(<ProfileActions profile={prof('request_sent')} />);
    expect(screen.getByRole('button', { name: 'Request sent' })).toBeDisabled();
    expect(screen.queryByText('Add friend')).toBeNull();
  });

  test('request_received: Accept shown, and no Decline (API has no decline endpoint)', () => {
    const onAccept = vi.fn();
    render(<ProfileActions profile={prof('request_received')} onAccept={onAccept} />);
    fireEvent.click(screen.getByRole('button', { name: /accept friend request from ann/i }));
    expect(onAccept).toHaveBeenCalled();
    expect(screen.queryByText('Decline')).toBeNull();
  });

  test('friends: Message only for friends', () => {
    const onMessage = vi.fn();
    render(<ProfileActions profile={prof('friends')} onMessage={onMessage} />);
    fireEvent.click(screen.getByRole('button', { name: /message ann/i }));
    expect(onMessage).toHaveBeenCalled();
  });

  test.each(['none', 'request_sent', 'request_received', 'self'])('%s: no Message button', (s) => {
    render(<ProfileActions profile={prof(s, { editable: s === 'self' })} />);
    expect(screen.queryByRole('button', { name: /message/i })).toBeNull();
  });

  test('self + editable: Edit bio; hidden while editing', () => {
    const onEdit = vi.fn();
    const { rerender } = render(<ProfileActions profile={prof('self', { editable: true })} onEdit={onEdit} />);
    fireEvent.click(screen.getByRole('button', { name: /edit bio/i }));
    expect(onEdit).toHaveBeenCalled();
    rerender(<ProfileActions profile={prof('self', { editable: true })} onEdit={onEdit} editing />);
    expect(screen.queryByRole('button', { name: /edit bio/i })).toBeNull();
  });

  test('busy ignores a second tap', () => {
    const onAdd = vi.fn();
    render(<ProfileActions profile={prof('none')} busy="add" onAdd={onAdd} />);
    fireEvent.click(screen.getByRole('button', { name: /add ann as a friend/i }));
    expect(onAdd).not.toHaveBeenCalled();
  });
});

describe('ProfileHeader', () => {
  test('shows username and relationship chip text, never an email', () => {
    const { container } = render(<ProfileHeader profile={{ username: 'Ann', email: 'ann@x.com', relationship: { state: 'friends' } }} />);
    expect(screen.getByText('Ann')).toBeInTheDocument();
    expect(screen.getByText('Friends')).toBeInTheDocument();
    expect(container.textContent).not.toContain('ann@x.com');
  });
});
