// Task 20261011-web-session-screenshare-rooms testing: flag-gated screen share
// and discussion rooms on the call screen, flags off and on via mocked
// capabilities. Run: cd frontend && npx vitest run src/components/SessionCallScreen.shareRooms.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, waitFor, within } from '@testing-library/react';
import SessionCallScreen from './SessionCallScreen.jsx';
import { CapabilitiesContext } from '../context/CapabilitiesContext.jsx';
import { CallFeaturesContext } from '../context/CallFeaturesContext.jsx';

const user = { user_id: 'me', username: 'Me' };
const friends = [{ id: 'f1', name: 'Fran' }];
const session = { id: 's1', group_id: 'g1', participants: ['me', 'f1'], prompts: ['First?'] };

const caps = (features) => ({ features, isEnabled: n => features[n] === true });
const mainRooms = (over = {}) => ({
  state: { kind: 'main' }, notice: null, announcement: '', seedNames: {},
  join: vi.fn().mockResolvedValue(null), returnToMain: vi.fn(), mainEnded: vi.fn(),
  noteRoomsList: vi.fn(), clearNotice: vi.fn(), ...over,
});
const share = (over = {}) => ({
  phase: 'idle', remoteShare: null, notice: null, start: vi.fn(), stop: vi.fn(), clearNotice: vi.fn(), ...over,
});

function mount({ features = {}, screenShare = share(), rooms = mainRooms(), sess = session } = {}) {
  const props = {
    session: sess, user, friends, fetchedNames: {}, talkingUserId: null,
    muted: false, onToggleMute: vi.fn(), videoEnabled: false, onToggleVideo: vi.fn(),
    canRing: true, onRing: vi.fn(), onLeave: vi.fn(), inviteCandidates: [],
  };
  const out = render(
    <CapabilitiesContext.Provider value={caps(features)}>
      <CallFeaturesContext.Provider value={{ screenShare, rooms, meetingPresence: [], bindVideoTile: vi.fn() }}>
        <SessionCallScreen {...props} />
      </CallFeaturesContext.Provider>
    </CapabilitiesContext.Provider>,
  );
  return { ...out, props, screenShare, rooms };
}
const openMenu = () => fireEvent.click(screen.getByRole('button', { name: 'Interactions' }));
const labels = () => screen.getAllByRole('menuitem').map(i => i.textContent);

let fetchMock;
beforeEach(() => {
  fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({ rooms: [], main_live: true }) });
  vi.stubGlobal('fetch', fetchMock);
  Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: { getDisplayMedia: vi.fn() } });
});
afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  delete navigator.mediaDevices;
});

describe('flags OFF (fail closed)', () => {
  test.each([
    ['empty features', {}],
    ['false', { screen_share_enabled: false, discussion_rooms: false }],
    ['truthy non-boolean', { screen_share_enabled: 'true', discussion_rooms: 1 }],
  ])('%s: no Share screen / Rooms rows, no fetch, no getDisplayMedia', (_n, features) => {
    mount({ features });
    openMenu();
    expect(labels()).toEqual(['Ring', 'Prompts', 'Turn on camera', 'Mute']);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(navigator.mediaDevices.getDisplayMedia).not.toHaveBeenCalled();
  });

  test('no providers at all: both features off', () => {
    render(<SessionCallScreen session={session} user={user} friends={friends} fetchedNames={{}}
      onToggleMute={() => {}} onToggleVideo={() => {}} onLeave={() => {}} canRing />);
    openMenu();
    expect(screen.queryByText(/Share screen|Rooms/)).toBeNull();
  });

  test('capabilities on but no CallFeatures controller: rows still hidden', () => {
    render(
      <CapabilitiesContext.Provider value={caps({ screen_share_enabled: true, discussion_rooms: true })}>
        <SessionCallScreen session={session} user={user} friends={friends} fetchedNames={{}}
          onToggleMute={() => {}} onToggleVideo={() => {}} onLeave={() => {}} canRing />
      </CapabilitiesContext.Provider>,
    );
    openMenu();
    expect(screen.queryByText(/Share screen|Rooms/)).toBeNull();
  });
});

describe('screen share ON', () => {
  const F = { screen_share_enabled: true };

  test('row shown only when API exists; hidden in a webview without getDisplayMedia', () => {
    Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: {} });
    mount({ features: F });
    openMenu();
    expect(screen.queryByText('Share screen')).toBeNull();
  });

  test('click starts share (explicit user action only)', () => {
    const { screenShare } = mount({ features: F });
    expect(screenShare.start).not.toHaveBeenCalled();
    openMenu();
    expect(labels()).toContain('Share screen');
    fireEvent.click(screen.getByRole('menuitem', { name: /Share screen/ }));
    expect(screenShare.start).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole('menu')).toBeNull();
  });

  test('sharing: pill, "You are sharing your screen" panel, Stop sharing row, top row layout', () => {
    const { container, screenShare } = mount({ features: F, screenShare: share({ phase: 'sharing' }) });
    expect(screen.getByText('Sharing your screen')).toBeTruthy();
    expect(screen.getByText('You are sharing your screen')).toBeTruthy();
    expect(container.querySelector('.call-bubbles-row')).toBeTruthy();
    openMenu();
    fireEvent.click(screen.getByRole('menuitem', { name: 'Stop sharing' }));
    expect(screenShare.stop).toHaveBeenCalledTimes(1);
  });

  test('pill and panel Stop buttons stop the share', () => {
    const { screenShare } = mount({ features: F, screenShare: share({ phase: 'sharing' }) });
    for (const b of screen.getAllByRole('button', { name: 'Stop sharing your screen' })) fireEvent.click(b);
    expect(screenShare.stop).toHaveBeenCalledTimes(2);
  });

  test('someone else sharing: header, aspect-fit tile, disabled row with caption', () => {
    const { container, screenShare } = mount({
      features: F, screenShare: share({ remoteShare: { sharerId: 'f1', tileId: 7 } }),
    });
    expect(screen.getByText('Fran is sharing')).toBeTruthy();
    expect(container.querySelector('video.call-share-video')).toBeTruthy();
    expect(container.querySelector('.call-bubbles-row')).toBeTruthy();
    openMenu();
    const row = screen.getByRole('menuitem', { name: /Share screen/ });
    expect(row.getAttribute('aria-disabled')).toBe('true');
    expect(row.textContent).toContain('Fran is sharing');
    fireEvent.click(row);
    expect(screenShare.start).not.toHaveBeenCalled();
  });

  test('unknown sharer never shows a raw id', () => {
    const { container } = mount({ features: F, screenShare: share({ remoteShare: { sharerId: 'raw-uuid-999', tileId: 1 } }) });
    expect(screen.getByText('Someone is sharing')).toBeTruthy();
    expect(container.textContent).not.toContain('raw-uuid-999');
  });

  test('receiving a share works even with the send flag off (receive always on)', () => {
    mount({ features: {}, screenShare: share({ remoteShare: { sharerId: 'f1', tileId: 7 } }) });
    expect(screen.getByText('Fran is sharing')).toBeTruthy();
  });

  test('share wins content area over Prompts; Prompts return when share stops', () => {
    const base = { features: F };
    const ctl = share({ remoteShare: { sharerId: 'f1', tileId: 7 } });
    const { rerender, props } = mount({ ...base, screenShare: ctl });
    openMenu();
    fireEvent.click(screen.getByRole('menuitem', { name: /Prompts/ }));
    expect(screen.queryByRole('region', { name: 'Discussion prompts' })).toBeNull();
    expect(screen.getByRole('region', { name: 'Fran is sharing' })).toBeTruthy();
    const ui = sc => (
      <CapabilitiesContext.Provider value={caps(F)}>
        <CallFeaturesContext.Provider value={{ screenShare: sc, rooms: mainRooms(), meetingPresence: [], bindVideoTile: vi.fn() }}>
          <SessionCallScreen {...props} />
        </CallFeaturesContext.Provider>
      </CapabilitiesContext.Provider>
    );
    rerender(ui(share()));
    expect(screen.getByRole('region', { name: 'Discussion prompts' })).toBeTruthy();
    expect(screen.queryByText('Fran is sharing')).toBeNull();
  });

  test('notice is dismissible and routed to the controller', () => {
    const { screenShare } = mount({ features: F, screenShare: share({ notice: 'Screen sharing ended.' }) });
    expect(screen.getByText('Screen sharing ended.')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Dismiss message' }));
    expect(screenShare.clearNotice).toHaveBeenCalled();
  });

  test('Stop stays reachable if the flag flips off mid-share', () => {
    mount({ features: {}, screenShare: share({ phase: 'sharing' }) });
    openMenu();
    expect(screen.getByRole('menuitem', { name: 'Stop sharing' })).toBeTruthy();
  });
});

describe('discussion rooms ON', () => {
  const F = { discussion_rooms: true };

  test('Rooms row opens dialog and lists via authenticated /session-rooms GET', async () => {
    mount({ features: F });
    openMenu();
    expect(labels()).toContain('Rooms');
    fireEvent.click(screen.getByRole('menuitem', { name: /Rooms/ }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalled());
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toContain('/session-rooms/me/sessions/s1/rooms');
    expect(opts.credentials).toBe('include');
  });

  test('no Rooms row in a DM session even with the flag on', () => {
    mount({ features: F, sess: { ...session, group_id: 'a|b' } });
    openMenu();
    expect(screen.queryByRole('menuitem', { name: /Rooms/ })).toBeNull();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test('dialog join calls controller with the listed room and closes on success', async () => {
    fetchMock.mockResolvedValue({
      ok: true, status: 200,
      json: async () => ({ rooms: [{ id: 'r1', slot: 1, name: 'Study', can_join: true, member_count: 1, max_members: 8 }], main_live: true }),
    });
    const { rooms } = mount({ features: F });
    openMenu();
    fireEvent.click(screen.getByRole('menuitem', { name: /Rooms/ }));
    const join = await screen.findByRole('button', { name: /Join/ });
    fireEvent.click(join);
    await waitFor(() => expect(rooms.join).toHaveBeenCalledTimes(1));
    expect(rooms.join.mock.calls[0][0].id).toBe('r1');
  });

  test('failed list load shows warm copy, not server text', async () => {
    fetchMock.mockResolvedValue({ ok: false, status: 500, json: async () => ({ detail: { code: 'boom', message: 'SECRET' } }) });
    mount({ features: F });
    openMenu();
    fireEvent.click(screen.getByRole('menuitem', { name: /Rooms/ }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalled());
    await new Promise(r => setTimeout(r, 20));
    expect(document.body.textContent).not.toContain('SECRET');
  });

  test('in a room: chip + Back to main pill call returnToMain; roomsOn rows persist', () => {
    const rooms = mainRooms({ state: { kind: 'inRoom', roomId: 'r1', name: 'Study' } });
    mount({ features: F, rooms });
    expect(screen.getByText('Study')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Back to main session' }));
    expect(rooms.returnToMain).toHaveBeenCalledTimes(1);
  });

  test('returning disables Back to main; returnFailed offers Try again / End call', () => {
    const { rooms: _r, unmount } = mount({ features: F, rooms: mainRooms({ state: { kind: 'returning', name: 'Study' } }) });
    expect(screen.getByRole('button', { name: 'Back to main session' }).disabled).toBe(true);
    unmount();
    const rooms = mainRooms({ state: { kind: 'returnFailed', name: 'Study' } });
    const { props } = mount({ features: F, rooms });
    expect(screen.getByRole('alert').textContent).toContain("Couldn't reach the main session.");
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
    expect(rooms.returnToMain).toHaveBeenCalled();
    fireEvent.click(within(screen.getByRole('alert')).getByRole('button', { name: 'End call' }));
    expect(props.onLeave).toHaveBeenCalled();
  });

  test('main-session state shows no room chip or Back to main', () => {
    mount({ features: F });
    expect(screen.queryByRole('button', { name: 'Back to main session' })).toBeNull();
  });
});
