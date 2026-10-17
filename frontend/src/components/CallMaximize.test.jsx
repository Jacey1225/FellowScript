// Task 20261016-call-maximize-tiles: tap-to-maximize for camera tiles (ActiveCard
// strip) and the incoming screen share (SessionCallScreen).
// Run: cd frontend && npx vitest run src/components/CallMaximize.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, within } from '@testing-library/react';
import { ActiveCard } from './SessionWidget.jsx';
import SessionCallScreen from './SessionCallScreen.jsx';
import { CapabilitiesContext } from '../context/CapabilitiesContext.jsx';
import { CallFeaturesContext } from '../context/CallFeaturesContext.jsx';

afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

const USER = { user_id: 'me', username: 'Me' };
const FRIENDS = [{ id: 'f1', name: 'Fran' }];
const SESSION = { id: 's1', title: 'Study', time_start: new Date(Date.now() - 1000).toISOString(), time_end: '', participants: ['me', 'f1'], prompts: [] };

function cardProps(over = {}) {
  return {
    session: SESSION, user: USER, friends: FRIENDS, ringCandidates: [], activeSessionId: 's1',
    talkingUserId: null, onJoin: vi.fn(), onLeave: vi.fn(), onEdit: vi.fn(), onDelete: vi.fn(),
    onNavigateVerse: vi.fn(), videoEnabled: true, onToggleVideo: vi.fn(), bindVideoTile: vi.fn(),
    videoTiles: [
      { tileId: 1, isLocal: true, userId: 'me' },
      { tileId: 2, isLocal: false, userId: 'f1' },
      { tileId: 3, isLocal: false, userId: '' },
    ],
    ...over,
  };
}
// The call screen has its own polite region; collect every status text.
const live = () => screen.queryAllByRole('status').map(n => n.textContent);

function mountCard(over) {
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: false, json: async () => ({}) }));
  const props = cardProps(over);
  const ui = p => (
    <CapabilitiesContext.Provider value={{ features: {}, isEnabled: () => false }}>
      <CallFeaturesContext.Provider value={{ screenShare: null, rooms: null, meetingPresence: [], bindVideoTile: vi.fn() }}>
        <ActiveCard {...p} />
      </CallFeaturesContext.Provider>
    </CapabilitiesContext.Provider>
  );
  const out = render(ui(props));
  return { ...out, props, rerenderWith: o => out.rerender(ui({ ...props, ...o })) };
}

describe('camera tile maximize (ActiveCard)', () => {
  test('strip tiles are labeled buttons; names come from the roster, never invented', () => {
    mountCard();
    expect(screen.getByRole('button', { name: 'Enlarge your video' })).toBeTruthy();
    expect(screen.getByRole('button', { name: "Enlarge Fran's video" })).toBeTruthy();
    // Unknown participant: generic label, no raw id, no made-up name.
    expect(screen.getByRole('button', { name: 'Enlarge video' })).toBeTruthy();
  });

  test('tap maximizes, moves the video (not duplicates it), focuses Back, shows name capsule', () => {
    const { container, props } = mountCard();
    expect(container.querySelectorAll('video')).toHaveLength(3);
    fireEvent.click(screen.getByRole('button', { name: "Enlarge Fran's video" }));
    const region = screen.getByRole('region', { name: 'Fran, enlarged video' });
    expect(within(region).getByText('Fran')).toBeTruthy();
    expect(document.activeElement).toBe(within(region).getByRole('button', { name: 'Back to everyone' }));
    expect(container.querySelectorAll('video')).toHaveLength(3); // 2 strip + 1 overlay
    expect(screen.queryByRole('button', { name: "Enlarge Fran's video" })).toBeNull();
    const overlayVideo = region.querySelector('video');
    expect(overlayVideo.style.objectFit).toBe('contain');
    expect(props.bindVideoTile).toHaveBeenCalledWith(2, overlayVideo);
  });

  test('own camera stays mirrored and is labeled as yours', () => {
    mountCard();
    fireEvent.click(screen.getByRole('button', { name: 'Enlarge your video' }));
    const region = screen.getByRole('region', { name: 'Your enlarged video' });
    expect(region.querySelector('video').style.transform).toBe('scaleX(-1)');
  });

  test('unknown name: no name capsule', () => {
    mountCard();
    fireEvent.click(screen.getByRole('button', { name: 'Enlarge video' }));
    const region = screen.getByRole('region', { name: 'Enlarged video' });
    expect(region.querySelector('.call-max-name')).toBeNull();
  });

  test('return via Back button, tapping the video, and Escape; focus goes back to the tile', () => {
    mountCard();
    const open = () => fireEvent.click(screen.getByRole('button', { name: "Enlarge Fran's video" }));
    open();
    fireEvent.click(screen.getByRole('button', { name: 'Back to everyone' }));
    expect(screen.queryByRole('region', { name: /enlarged video/ })).toBeNull();
    expect(document.activeElement).toBe(screen.getByRole('button', { name: "Enlarge Fran's video" }));

    open();
    fireEvent.click(screen.getByRole('button', { name: 'Return to everyone' }));
    expect(screen.queryByRole('region', { name: /enlarged video/ })).toBeNull();

    open();
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(screen.queryByRole('region', { name: /enlarged video/ })).toBeNull();
    expect(document.activeElement).toBe(screen.getByRole('button', { name: "Enlarge Fran's video" }));
  });

  test('participant leaves: auto-restore with a warm announcement', () => {
    const { rerenderWith } = mountCard();
    fireEvent.click(screen.getByRole('button', { name: "Enlarge Fran's video" }));
    rerenderWith({
      session: { ...SESSION, participants: ['me'] },
      videoTiles: [{ tileId: 1, isLocal: true, userId: 'me' }, { tileId: 3, isLocal: false, userId: '' }],
    });
    expect(screen.queryByRole('region', { name: /enlarged video/ })).toBeNull();
    expect(live()).toContain('Fran left the call. Back to everyone.');
  });

  test('camera turned off (still in call): auto-restore', () => {
    const { rerenderWith } = mountCard();
    fireEvent.click(screen.getByRole('button', { name: "Enlarge Fran's video" }));
    rerenderWith({ videoTiles: [{ tileId: 1, isLocal: true, userId: 'me' }] });
    expect(screen.queryByRole('region', { name: /enlarged video/ })).toBeNull();
    expect(live()).toContain('Fran turned their camera off. Back to everyone.');
  });

  test('own camera off: auto-restore', () => {
    const { rerenderWith } = mountCard();
    fireEvent.click(screen.getByRole('button', { name: 'Enlarge your video' }));
    rerenderWith({ videoTiles: [{ tileId: 2, isLocal: false, userId: 'f1' }] });
    expect(screen.queryByRole('region', { name: /enlarged video/ })).toBeNull();
    expect(live()).toContain('Your camera is off. Back to everyone.');
  });

  test('unknown participant tile removed: generic announcement, no invented name', () => {
    const { rerenderWith } = mountCard();
    fireEvent.click(screen.getByRole('button', { name: 'Enlarge video' }));
    rerenderWith({ videoTiles: [{ tileId: 1, isLocal: true, userId: 'me' }] });
    expect(live()).toContain('Back to everyone.');
  });

  test('leaving the call clears the overlay silently', () => {
    const { rerenderWith } = mountCard();
    fireEvent.click(screen.getByRole('button', { name: "Enlarge Fran's video" }));
    rerenderWith({ activeSessionId: null, videoTiles: [] });
    expect(screen.queryByRole('region', { name: /enlarged video/ })).toBeNull();
    expect(live().join('')).toBe('');
  });
});

describe('screen share maximize (SessionCallScreen)', () => {
  const share = (over = {}) => ({
    phase: 'idle', remoteShare: { sharerId: 'f1', tileId: 7 }, notice: null,
    start: vi.fn(), stop: vi.fn(), clearNotice: vi.fn(), ...over,
  });
  const base = {
    session: SESSION, user: USER, friends: FRIENDS, fetchedNames: {}, talkingUserId: null,
    muted: false, onToggleMute: vi.fn(), videoEnabled: false, onToggleVideo: vi.fn(),
    canRing: false, onRing: vi.fn(), onLeave: vi.fn(), inviteCandidates: [],
  };
  function mount(sc) {
    const bindVideoTile = vi.fn();
    const ui = s => (
      <CapabilitiesContext.Provider value={{ features: {}, isEnabled: () => false }}>
        <CallFeaturesContext.Provider value={{ screenShare: s, rooms: null, meetingPresence: [], bindVideoTile }}>
          <SessionCallScreen {...base} />
        </CallFeaturesContext.Provider>
      </CapabilitiesContext.Provider>
    );
    const out = render(ui(sc));
    return { ...out, bindVideoTile, rerenderShare: s => out.rerender(ui(s)) };
  }

  test('no heading; bare tile with an enlarge button and decorative glyph', () => {
    const { container } = mount(share());
    expect(screen.queryByRole('heading')).toBeNull();
    expect(screen.getByRole('region', { name: 'Fran is sharing' })).toBeTruthy();
    expect(screen.getByRole('button', { name: "Enlarge Fran's shared screen" })).toBeTruthy();
    expect(container.querySelector('.call-max-glyph').getAttribute('aria-hidden')).toBe('true');
  });

  test('tap maximizes keeping the same video element; Back returns focus to the tile', () => {
    const { container, bindVideoTile } = mount(share());
    const video = container.querySelector('video');
    fireEvent.click(screen.getByRole('button', { name: "Enlarge Fran's shared screen" }));
    const region = screen.getByRole('region', { name: 'Enlarged shared screen' });
    expect(region.className).toContain('call-share-max');
    expect(container.querySelector('video')).toBe(video);
    expect(bindVideoTile).toHaveBeenCalledTimes(1);
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Back to everyone' }));
    // participant bubbles stay visible above it
    expect(container.querySelector('.call-bubbles')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Back to everyone' }));
    expect(screen.getByRole('region', { name: 'Fran is sharing' })).toBeTruthy();
    expect(document.activeElement).toBe(screen.getByRole('button', { name: "Enlarge Fran's shared screen" }));
  });

  test('tapping the enlarged share and Escape both return', () => {
    mount(share());
    fireEvent.click(screen.getByRole('button', { name: "Enlarge Fran's shared screen" }));
    fireEvent.click(screen.getByRole('button', { name: 'Return to everyone' }));
    expect(screen.queryByRole('region', { name: 'Enlarged shared screen' })).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: "Enlarge Fran's shared screen" }));
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(screen.queryByRole('region', { name: 'Enlarged shared screen' })).toBeNull();
  });

  test('sharer stops while enlarged: restores and announces; next share starts normal', () => {
    const { rerenderShare } = mount(share());
    fireEvent.click(screen.getByRole('button', { name: "Enlarge Fran's shared screen" }));
    rerenderShare(share({ remoteShare: null }));
    expect(screen.queryByRole('region', { name: 'Enlarged shared screen' })).toBeNull();
    expect(screen.getAllByRole('status')[0].textContent).toBe('Fran stopped sharing. Back to everyone.');
    rerenderShare(share({ remoteShare: { sharerId: 'f1', tileId: 9 } }));
    expect(screen.getByRole('region', { name: 'Fran is sharing' })).toBeTruthy();
  });

  test('stopping an un-enlarged share keeps the plain announcement', () => {
    const { rerenderShare } = mount(share());
    rerenderShare(share({ remoteShare: null }));
    expect(screen.getAllByRole('status')[0].textContent).toBe('Fran stopped sharing');
  });

  test('own share panel is not maximizable', () => {
    mount(share({ phase: 'sharing', remoteShare: null }));
    expect(screen.queryByRole('button', { name: /Enlarge/ })).toBeNull();
  });
});
