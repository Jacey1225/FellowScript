// Regression test for task 20260904-compliance-reliability-bugs's Chime
// call-join fix: SessionWidget must actually surface useSessions.js's
// joinError state as a visible error + Retry/dismiss affordance next to the
// affected session's Join button -- previously a failed call-join produced
// zero user-visible signal anywhere in the UI.
//
// Run with: cd frontend && npm test -- --run src/components/SessionWidget.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import SessionWidget from './SessionWidget.jsx';

afterEach(() => cleanup());

const USER = { user_id: 'user-1', username: 'tester' };

// An "upcoming" (not yet started) session so SessionWidget renders it via
// UpcomingCard, which also wires up JoinErrorRow.
const UPCOMING_SESSION = {
  id: 'session-1',
  title: 'Evening Study',
  time_start: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
  time_end: '',
  participants: [],
};

function baseProps(overrides = {}) {
  return {
    sessions: [UPCOMING_SESSION],
    user: USER,
    activeSessionId: null,
    talkingUserId: null,
    onJoin: vi.fn(),
    onLeave: vi.fn(),
    onEdit: vi.fn(),
    onDelete: vi.fn(),
    onNavigateVerse: vi.fn(),
    videoEnabled: false,
    videoTiles: [],
    onToggleVideo: vi.fn(),
    bindVideoTile: vi.fn(),
    joinError: null,
    onClearJoinError: vi.fn(),
    ...overrides,
  };
}

describe('SessionWidget — join-error surfacing (Chime call-join no longer fails silently)', () => {
  test('no error row renders when joinError is null', () => {
    render(<SessionWidget {...baseProps()} />);
    expect(screen.queryByText(/Could not/)).toBeNull();
    expect(screen.queryByRole('button', { name: 'Retry' })).toBeNull();
  });

  test('a joinError for this session renders its message plus Retry and Dismiss controls', () => {
    const props = baseProps({
      joinError: { sessionId: 'session-1', message: 'Could not start the call. Please try again.' },
    });
    render(<SessionWidget {...props} />);

    expect(screen.getByText('Could not start the call. Please try again.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Retry' })).toBeTruthy();
  });

  test('a joinError for a *different* session does not render on this session\'s card', () => {
    const props = baseProps({
      joinError: { sessionId: 'some-other-session', message: 'Could not start the call. Please try again.' },
    });
    render(<SessionWidget {...props} />);

    expect(screen.queryByText('Could not start the call. Please try again.')).toBeNull();
  });

  test('clicking Retry calls onJoin with the session id again', () => {
    const onJoin = vi.fn();
    const props = baseProps({
      onJoin,
      joinError: { sessionId: 'session-1', message: 'Could not join the call. Please try again.' },
    });
    render(<SessionWidget {...props} />);

    fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
    expect(onJoin).toHaveBeenCalledWith('session-1');
  });

  test('dismissing the error calls onClearJoinError', () => {
    const onClearJoinError = vi.fn();
    const props = baseProps({
      onClearJoinError,
      joinError: { sessionId: 'session-1', message: 'Could not join the call. Please try again.' },
    });
    render(<SessionWidget {...props} />);

    fireEvent.click(screen.getByTitle('Dismiss'));
    expect(onClearJoinError).toHaveBeenCalled();
  });
});
