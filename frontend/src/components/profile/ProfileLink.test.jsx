// Task 20261030-profile-everywhere (step 9). Shared profile tap target, helpers,
// and the wired web spots: tappable vs untappable, no-id cases, pinned avatar
// outside the jump button, desktop allow-pattern.
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom';
import ProfileLink from './ProfileLink.jsx';
import useProfileNav from '../../hooks/useProfileNav.js';
import { isProfileId, profilePath } from '../../lib/profileId.js';
import { isAllowedDesktopRoute } from '../../lib/desktopScope.js';
import MentionText from '../MentionText.jsx';
import ChatHeaderIdentity from '../ChatHeaderIdentity.jsx';
import { PinnedListBody } from '../PinnedMessagesPanel.jsx';

afterEach(cleanup);
const ID = '123e4567-e89b-42d3-a456-426614174000';
const ID2 = '223e4567-e89b-42d3-a456-426614174001';

function Where() { const l = useLocation(); return <div data-testid="where">{l.pathname}</div>; }
function wrap(ui) {
  return render(<MemoryRouter initialEntries={['/']}>{ui}<Where /></MemoryRouter>);
}

describe('profileId helpers', () => {
  test('isProfileId accepts UUIDs only', () => {
    expect(isProfileId(ID)).toBe(true);
    expect(isProfileId(ID.toUpperCase())).toBe(true);
    for (const bad of ['', 'abcd', ID + 'x', ' ' + ID, '../etc', `${ID}/x`, null, undefined, 42, {}]) {
      expect(isProfileId(bad)).toBe(false);
    }
  });
  test('profilePath builds /profile/<id> or null', () => {
    expect(profilePath(ID)).toBe(`/profile/${ID}`);
    expect(profilePath('nope')).toBeNull();
    expect(profilePath(undefined)).toBeNull();
  });
  test('every profilePath is allowed by the desktop scope; non-ids never produce one', () => {
    expect(isAllowedDesktopRoute(profilePath(ID))).toBe(true);
    expect(isAllowedDesktopRoute(profilePath(ID2))).toBe(true);
    expect(isAllowedDesktopRoute(`/profile/${ID}/x`)).toBe(false);
    expect(isAllowedDesktopRoute('/profile/abc')).toBe(false);
  });
});

describe('ProfileLink', () => {
  test('valid id and name renders a link with label, href, 44px min', () => {
    wrap(<ProfileLink userId={ID} username="Ada"><span>Ada</span></ProfileLink>);
    const a = screen.getByRole('link', { name: "View Ada's profile" });
    expect(a.getAttribute('href')).toBe(`/profile/${ID}`);
    expect(a.style.minWidth).toBe('44px');
    expect(a.style.minHeight).toBe('44px');
    expect(a.textContent).toBe('Ada');
    expect(a.getAttribute('aria-label')).not.toContain(ID);
  });
  test('click navigates and does not bubble to the parent', () => {
    const parent = vi.fn();
    wrap(<div onClick={parent}><ProfileLink userId={ID} username="Ada">Ada</ProfileLink></div>);
    fireEvent.click(screen.getByRole('link'));
    expect(screen.getByTestId('where').textContent).toBe(`/profile/${ID}`);
    expect(parent).not.toHaveBeenCalled();
  });
  test.each([
    ['undefined id', undefined, 'Ada'],
    ['empty id', '', 'Ada'],
    ['non-uuid id (slice fallback)', ID.slice(0, 8), 'Ada'],
    ['placeholder Someone', ID, 'Someone'],
    ['placeholder A member', ID, 'A member'],
    ['placeholder Them', ID, 'them'],
    ['placeholder You', ID, 'You'],
    ['empty name', ID, ''],
    ['missing name', ID, undefined],
  ])('renders plain children, no link, for %s', (_n, id, name) => {
    wrap(<ProfileLink userId={id} username={name}><span data-testid="kid">x</span></ProfileLink>);
    expect(screen.queryByRole('link')).toBeNull();
    expect(screen.getByTestId('kid').textContent).toBe('x');
  });
  test('outside a Router it fails closed instead of throwing', () => {
    render(<ProfileLink userId={ID} username="Ada"><span data-testid="kid">x</span></ProfileLink>);
    expect(screen.queryByRole('link')).toBeNull();
    expect(screen.getByTestId('kid')).toBeTruthy();
  });
});

describe('useProfileNav', () => {
  function Probe({ id }) {
    const open = useProfileNav();
    return <button onClick={() => { window.__ret = open(id); }}>go</button>;
  }
  test('navigates for a UUID and returns true', () => {
    wrap(<Probe id={ID} />);
    fireEvent.click(screen.getByText('go'));
    expect(window.__ret).toBe(true);
    expect(screen.getByTestId('where').textContent).toBe(`/profile/${ID}`);
  });
  test('returns false and stays put for a non-id', () => {
    wrap(<Probe id="abc" />);
    fireEvent.click(screen.getByText('go'));
    expect(window.__ret).toBe(false);
    expect(screen.getByTestId('where').textContent).toBe('/');
  });
});

describe('MentionText wiring', () => {
  const text = 'hi @ada and @bob';
  const mentions = [
    { start: 3, length: 4, username: 'ada', userId: ID },
    { start: 12, length: 4, username: 'bob', userId: 'not-a-uuid' },
  ];
  test('mention with UUID is a link; mention without is plain bold text', () => {
    wrap(<MentionText text={text} mentions={mentions} />);
    const links = screen.getAllByRole('link');
    expect(links).toHaveLength(1);
    expect(links[0].getAttribute('href')).toBe(`/profile/${ID}`);
    expect(links[0].textContent).toBe('@ada');
    expect(screen.getByText('@bob').closest('a')).toBeNull();
  });
  test('no mentions renders plain text', () => {
    wrap(<MentionText text="hello" mentions={[]} />);
    expect(screen.queryByRole('link')).toBeNull();
  });
});

describe('ChatHeaderIdentity', () => {
  test('one button with the same label, calls onViewProfile(contact.id)', () => {
    const onView = vi.fn();
    wrap(<ChatHeaderIdentity contact={{ id: ID, name: 'Ada' }} onViewProfile={onView} />);
    fireEvent.click(screen.getByRole('button', { name: "View Ada's profile" }));
    expect(onView).toHaveBeenCalledWith(ID);
  });
});

describe('PinnedListBody avatar link', () => {
  const pin = (fromUserId, from = 'Ada') => ({
    messageId: 'm' + fromUserId, pinnedBy: 'x', message: { from, fromUserId, text: 'hello', timestamp: 1 },
  });
  const list = (pins) => ({ pins, status: 'ready', hasMore: false, moreLoading: false });
  const props = { viewerId: 'v', onJump: vi.fn(), onUnpin: vi.fn(), onLoadMore: vi.fn(), onRetry: vi.fn() };

  test('author avatar link sits outside the jump button (no nested interactive)', () => {
    const onJump = vi.fn();
    wrap(<PinnedListBody {...props} onJump={onJump} list={list([pin(ID)])} />);
    const link = screen.getByRole('link', { name: "View Ada's profile" });
    expect(link.closest('button')).toBeNull();
    expect(link.getAttribute('href')).toBe(`/profile/${ID}`);
    fireEvent.click(link);
    expect(onJump).not.toHaveBeenCalled();
    expect(screen.getByTestId('where').textContent).toBe(`/profile/${ID}`);
  });
  test('row still jumps from the main button', () => {
    const onJump = vi.fn();
    wrap(<PinnedListBody {...props} onJump={onJump} list={list([pin(ID)])} />);
    const jump = document.querySelector('.pins-row-main');
    expect(jump.querySelector('a')).toBeNull();
    fireEvent.click(jump);
    expect(onJump).toHaveBeenCalledTimes(1);
  });
  test.each([[''], [undefined], ['abc']])('no linkable id (%s) leaves avatar untappable', (id) => {
    wrap(<PinnedListBody {...props} list={list([pin(id)])} />);
    expect(screen.queryByRole('link')).toBeNull();
  });
  test('placeholder author (no name) is untappable even with an id', () => {
    wrap(<PinnedListBody {...props} list={list([pin(ID, '')])} />);
    expect(screen.queryByRole('link')).toBeNull();
  });
});
