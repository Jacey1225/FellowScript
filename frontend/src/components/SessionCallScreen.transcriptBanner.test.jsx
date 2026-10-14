// Task 20261013-session-call-live-transcript-summary testing: consent banner.
// Run: cd frontend && npx vitest run src/components/SessionCallScreen.transcriptBanner.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import SessionCallScreen from './SessionCallScreen.jsx';
import { CallFeaturesContext } from '../context/CallFeaturesContext.jsx';
import { TRANSCRIPT_CONSENT_COPY } from '../lib/transcriptRelay.js';

afterEach(cleanup);

const user = { user_id: 'me', username: 'Me' };
const props = () => ({
  session: { id: 's1', participants: ['me'], prompts: [] }, user, friends: [], fetchedNames: {}, talkingUserId: null,
  muted: false, onToggleMute: vi.fn(), videoEnabled: false, onToggleVideo: vi.fn(),
  canRing: false, onRing: vi.fn(), onLeave: vi.fn(), inviteCandidates: [],
});
const mount = (ctx) => render(
  <CallFeaturesContext.Provider value={{ screenShare: null, rooms: null, meetingPresence: [], bindVideoTile: vi.fn(), ...ctx }}>
    <SessionCallScreen {...props()} />
  </CallFeaturesContext.Provider>,
);

describe('transcription consent banner', () => {
  test('shown to every participant while the main call is transcribed', () => {
    mount({ transcriptionActive: true });
    const banner = screen.getByText(TRANSCRIPT_CONSENT_COPY);
    expect(banner.closest('[role="status"]')).toBeTruthy();
  });
  test('absent when not transcribing (default context too)', () => {
    mount({ transcriptionActive: false });
    expect(screen.queryByText(TRANSCRIPT_CONSENT_COPY)).toBeNull();
    cleanup();
    render(<SessionCallScreen {...props()} />);
    expect(screen.queryByText(TRANSCRIPT_CONSENT_COPY)).toBeNull();
  });
  test('hidden while viewing a discussion room (separate, untranscribed meeting)', () => {
    mount({ transcriptionActive: true, rooms: {
      state: { kind: 'inRoom', roomId: 'r1' }, notice: null, announcement: '', seedNames: {},
      join: vi.fn(), returnToMain: vi.fn(), mainEnded: vi.fn(), noteRoomsList: vi.fn(), clearNotice: vi.fn() } });
    expect(screen.queryByText(TRANSCRIPT_CONSENT_COPY)).toBeNull();
  });
});
