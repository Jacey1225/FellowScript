// Tests for the desktop Sessions submenu (task 20260930-desktop-sessions-submenu).
// Run with: cd frontend && npm test -- --run src/components/SessionsMenu.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, within } from '@testing-library/react';
import SessionsMenu, { splitSessions } from './SessionsMenu.jsx';

afterEach(() => cleanup());

const H = 3600e3;
const iso = off => new Date(Date.now() + off).toISOString();
const mk = (id, title, start, end = '', participants = []) =>
  ({ id, title, time_start: iso(start), time_end: end === '' ? '' : iso(end), participants });

function props(o = {}) {
  return {
    sessions: [], activeSessionId: null, joinError: null, onClearJoinError: vi.fn(),
    onJoin: vi.fn(), onLeave: vi.fn(), onEdit: vi.fn(), onDelete: vi.fn(),
    onOpenSessionCreator: vi.fn(), user: { user_id: 'u1' }, talkingUserId: null,
    onNavigateVerse: vi.fn(), videoEnabled: false, videoTiles: [],
    onToggleVideo: vi.fn(), bindVideoTile: vi.fn(), ...o,
  };
}
const openMenu = () => fireEvent.click(screen.getByRole('button', { name: /^Sessions/ }));

describe('splitSessions', () => {
  test('upcoming soonest-first, past most-recent-first, ended+empty hidden, active excluded', () => {
    const sessions = [
      mk('late', 'Late', 5 * H), mk('soon', 'Soon', 1 * H),
      mk('old', 'Old', -10 * H, -9 * H, ['x']),
      mk('recent', 'Recent', -3 * H, -2 * H, ['x']),
      mk('ghost', 'Ghost', -5 * H, -4 * H, []),
      mk('act', 'Active', 2 * H),
    ];
    const { upcoming, past } = splitSessions(sessions, 'act');
    expect(upcoming.map(s => s.id)).toEqual(['soon', 'late']);
    expect(past.map(s => s.id)).toEqual(['recent', 'old']);
  });
  test('tolerates undefined sessions', () => {
    expect(splitSessions(undefined, null)).toEqual({ upcoming: [], past: [] });
  });
});

describe('SessionsMenu', () => {
  test('closed by default; button toggles menu and aria-expanded', () => {
    render(<SessionsMenu {...props()} />);
    const btn = screen.getByRole('button', { name: 'Sessions' });
    expect(btn).toHaveAttribute('aria-expanded', 'false');
    expect(screen.queryByRole('dialog')).toBeNull();
    fireEvent.click(btn);
    expect(btn).toHaveAttribute('aria-expanded', 'true');
    expect(screen.getByRole('dialog', { name: 'Sessions' })).toBeInTheDocument();
    fireEvent.click(btn);
    expect(screen.queryByRole('dialog')).toBeNull();
  });

  test('lists sections in order', () => {
    render(<SessionsMenu {...props({ sessions: [
      mk('b', 'Bravo', 4 * H), mk('a', 'Alpha', 1 * H),
      mk('p', 'Prior', -3 * H, -2 * H, ['x']),
    ] })} />);
    openMenu();
    const text = screen.getByRole('dialog').textContent;
    expect(text.indexOf('Alpha')).toBeLessThan(text.indexOf('Bravo'));
    expect(text.indexOf('Upcoming')).toBeLessThan(text.indexOf('Past'));
    expect(text.indexOf('Bravo')).toBeLessThan(text.indexOf('Prior'));
  });

  test('empty state shows note and schedule action', () => {
    render(<SessionsMenu {...props()} />);
    openMenu();
    expect(screen.getByText('No sessions scheduled.')).toBeInTheDocument();
    expect(screen.getByText('Schedule session')).toBeInTheDocument();
  });

  test('Schedule session calls creator, closes menu, returns focus to button', () => {
    const p = props();
    render(<SessionsMenu {...p} />);
    openMenu();
    fireEvent.click(screen.getByText('Schedule session'));
    expect(p.onOpenSessionCreator).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Sessions' }));
  });

  test('Escape, close button and scrim each dismiss', () => {
    render(<SessionsMenu {...props()} />);
    openMenu();
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(screen.queryByRole('dialog')).toBeNull();
    openMenu();
    fireEvent.click(screen.getByLabelText('Close sessions menu'));
    expect(screen.queryByRole('dialog')).toBeNull();
    openMenu();
    fireEvent.click(screen.getByTestId('sessions-menu-scrim'));
    expect(screen.queryByRole('dialog')).toBeNull();
  });

  test('row actions wire through: join, edit, delete', () => {
    // Starts in 5 minutes: inside the 10 minute join grace. Host-only controls
    // need creator_id === user.user_id; delete asks for confirmation first.
    const p = props({ sessions: [{ ...mk('s1', 'Study', 5 * 60e3), creator_id: 'u1' }] });
    render(<SessionsMenu {...p} />);
    openMenu();
    const dlg = within(screen.getByRole('dialog'));
    fireEvent.click(dlg.getByText('Join'));
    expect(p.onJoin).toHaveBeenCalledWith('s1');
    fireEvent.click(dlg.getByTitle('Edit session'));
    expect(p.onEdit).toHaveBeenCalledWith(p.sessions[0]);
    fireEvent.click(dlg.getByTitle('Delete session'));
    expect(p.onDelete).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }));
    expect(p.onDelete).toHaveBeenCalledWith('s1');
  });

  test('joinError surfaces in menu and button label signals attention', () => {
    render(<SessionsMenu {...props({
      sessions: [mk('s1', 'Study', 2 * H)],
      joinError: { sessionId: 's1', message: 'Could not start the call.' },
    })} />);
    expect(screen.getByRole('button', { name: 'Sessions, needs attention' })).toBeInTheDocument();
    openMenu();
    expect(screen.getByText('Could not start the call.')).toBeInTheDocument();
  });

  test('joined session is excluded from the menu and button flags in-call', () => {
    render(<SessionsMenu {...props({
      sessions: [mk('s1', 'Joined One', -H, ''), mk('s2', 'Other', 2 * H)],
      activeSessionId: 's1',
    })} />);
    expect(screen.getByRole('button', { name: 'Sessions, in a call' })).toBeInTheDocument();
    openMenu();
    expect(screen.queryByText('Joined One')).toBeNull();
    expect(screen.getByText('Other')).toBeInTheDocument();
  });
});
