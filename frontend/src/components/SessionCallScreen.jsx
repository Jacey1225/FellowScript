import React, { useCallback, useEffect, useRef, useState } from 'react';
import ProfileLink from './profile/ProfileLink.jsx';
import {
  AudioMutedOutlined, AudioOutlined, BellOutlined, CloseOutlined, CommentOutlined,
  DesktopOutlined, EllipsisOutlined, FullscreenOutlined, PhoneOutlined, RollbackOutlined, TeamOutlined,
  UserOutlined, VideoCameraOutlined,
} from '@ant-design/icons';
import { useCapabilities } from '../hooks/useCapabilities.js';
import { useCallFeatures } from '../context/CallFeaturesContext.jsx';
import {
  SCREEN_SHARE_FLAG, callLayoutMode, canOfferScreenShare, contentAreaKind, isDisplayCaptureSupported,
} from '../lib/screenShareState.js';
import { ROOM_COPY, isBusy, roomsAvailable, showsBackToMain, stateRoomName } from '../lib/callRoomState.js';
import { MaxBackButton, useEscapeToClose } from './CallMaximize.jsx';
import SessionRoomsModal from './SessionRoomsModal.jsx';
import { TRANSCRIPT_CONSENT_COPY } from '../lib/transcriptRelay.js';

// Joined-state call screen for the desktop Session card (task
// 20261011-web-session-ui-parity). Mirrors iOS ChimeCallView(+Session): bottom
// dock (round End Call + round Interactions button), Muted pill/badge, scattered
// bubbles vs one top row when Prompts are showing, and the untitled Prompts
// panel. Styles live in global.css under .call-*.
//
// Task 20261011-web-session-screenshare-rooms adds two server-flagged features
// (both fail closed: hidden unless the capability is explicitly true, and the
// whole feature is absent outside a CallFeaturesContext provider):
//   * Share screen (features.screen_share_enabled): send via Chime content
//     share, receive in the content area, header pill, row states.
//   * Rooms (features.discussion_rooms): Rooms dialog, Back to main, room chip.

// Resolves a participant id to a display name from the signed-in user and the
// friends list. Returns null when unknown: callers show a neutral glyph and
// never a raw id.
export function resolveName(uid, { user, friends, fetched }) {
  if (!uid) return null;
  if (uid === user?.user_id) return user?.username || null;
  const friend = (friends || []).find(f => f.id === uid);
  if (friend?.name) return friend.name;
  return fetched?.[uid] || null;
}

function Bubble({ name, userId, isYou, talking, compact, style }) {
  const label = isYou ? 'You' : (name || 'Member');
  return (
    <div className={`call-bubble${compact ? ' call-bubble-compact' : ''}`} style={style}>
      <ProfileLink userId={userId} username={name} style={{ flexDirection: 'column', gap: '0.25rem', maxWidth: '100%' }}>
        <div className={`call-bubble-disc${talking ? ' call-bubble-talking' : ''}`} aria-hidden="true">
          {name ? name[0].toUpperCase() : <UserOutlined />}
        </div>
        <span className="call-bubble-name">{label}</span>
      </ProfileLink>
      {talking && <span className="visually-hidden"> is speaking</span>}
    </div>
  );
}

const SCATTER_OFFSETS = [0, 16, -4, 22, 6, 14];

// Warm, self-dismissing notice with an explicit dismiss (no timing-only info).
function CallNotice({ text, onDismiss }) {
  if (!text) return null;
  return (
    <div className="call-notice" role="status">
      <span>{text}</span>
      <button type="button" className="call-notice-close" aria-label="Dismiss message" onClick={onDismiss}>
        <CloseOutlined aria-hidden="true" />
      </button>
    </div>
  );
}

// Persistent "you are sharing" indicator; one tap stops (no confirmation).
function SharePill({ onStop }) {
  return (
    <button type="button" className="call-share-pill" aria-label="Stop sharing your screen" onClick={onStop}>
      <span className="call-share-dot" aria-hidden="true" />
      <span>Sharing your screen</span>
      <span className="call-share-pill-stop" aria-hidden="true">Stop</span>
    </button>
  );
}

// Incoming share: the bare aspect-fit tile (no heading; the region keeps its
// "<Name> is sharing" accessible name). The whole tile is a button that
// enlarges it to fill the stage; the same <video> element stays mounted across
// both states so the Chime tile never needs rebinding. Closing a share you
// receive is not possible.
function RemoteShareTile({ tileId, name, bindVideoTile, maximized, onToggle }) {
  const refCallback = useCallback(el => {
    if (el && bindVideoTile) bindVideoTile(tileId, el);
  }, [tileId, bindVideoTile]);
  const surfaceRef = useRef(null);
  const wasMax = useRef(false);
  // Returning focus: the surface button persists, so hand focus back to it.
  useEffect(() => {
    if (wasMax.current && !maximized) surfaceRef.current?.focus();
    wasMax.current = maximized;
  }, [maximized]);
  useEscapeToClose(maximized, onToggle);
  return (
    <section
      className={`call-share-area${maximized ? ' call-share-max' : ''}`}
      role="region"
      aria-label={maximized ? 'Enlarged shared screen' : `${name} is sharing`}
    >
      <div className="call-share-frame">
        {maximized && <MaxBackButton onClick={onToggle} />}
        <button
          ref={surfaceRef}
          type="button"
          className="call-share-surface"
          aria-label={maximized ? 'Return to everyone' : `Enlarge ${name}'s shared screen`}
          onClick={onToggle}
        >
          <video ref={refCallback} autoPlay playsInline muted className="call-share-video" aria-hidden="true" />
          {!maximized && (
            <span className="call-max-glyph" aria-hidden="true"><FullscreenOutlined /></span>
          )}
        </button>
      </div>
    </section>
  );
}

// Shown in MY content area while my own share is live (I never see my frames).
function YourSharePanel({ onStop }) {
  return (
    <section className="call-share-area call-share-self" role="region" aria-label="Your screen share">
      <DesktopOutlined className="call-share-self-icon" aria-hidden="true" />
      <p className="call-share-self-text">You are sharing your screen</p>
      <button type="button" className="call-share-stop-btn" aria-label="Stop sharing your screen" onClick={onStop}>
        Stop sharing
      </button>
    </section>
  );
}

export function PromptsPanel({ prompts, onClose }) {
  const [emphasized, setEmphasized] = useState(() => new Set());
  const toggle = i => setEmphasized(prev => {
    const next = new Set(prev);
    if (next.has(i)) next.delete(i); else next.add(i);
    return next;
  });
  return (
    <section className="call-prompts" role="region" aria-label="Discussion prompts">
      <button type="button" className="call-prompts-close" aria-label="Close prompts" onClick={onClose}>
        <CloseOutlined aria-hidden="true" />
      </button>
      {prompts.length === 0 ? (
        <p className="call-prompts-empty">No prompts for this session.</p>
      ) : (
        <ol className="call-prompts-list">
          {prompts.map((p, i) => (
            <li key={i}>
              {/* Emphasis is local only: nothing is sent to other participants. */}
              <button
                type="button"
                className={`call-prompt-card${emphasized.has(i) ? ' call-prompt-card-on' : ''}`}
                aria-pressed={emphasized.has(i)}
                onClick={() => toggle(i)}
              >
                <span className="call-prompt-num" aria-hidden="true">{i + 1}</span>
                <span className="call-prompt-text">{p}</span>
              </button>
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}

export default function SessionCallScreen({
  session, user, friends, fetchedNames, talkingUserId,
  muted, onToggleMute, videoEnabled, onToggleVideo,
  canRing, onRing, onLeave, inviteCandidates,
}) {
  const { isEnabled } = useCapabilities();
  const { screenShare, rooms, meetingPresence, bindVideoTile, transcriptionActive } = useCallFeatures();
  const [menuOpen, setMenuOpen] = useState(false);
  const [promptsOpen, setPromptsOpen] = useState(false);
  const [roomsOpen, setRoomsOpen] = useState(false);
  const [liveText, setLiveText] = useState('');
  const [shareMaximized, setShareMaximized] = useState(false);
  const btnRef = useRef(null);
  const menuRef = useRef(null);

  // ── Screen share state (all fail closed) ──────────────────────────────────
  const sharePhase = screenShare?.phase || 'idle';
  const remoteShare = screenShare?.remoteShare || null;
  const sharingSelf = sharePhase === 'sharing';
  const shareFlag = isEnabled(SCREEN_SHARE_FLAG) === true;
  const offerShare = !!screenShare && canOfferScreenShare({ flagEnabled: shareFlag, supported: isDisplayCaptureSupported() });
  // Stop must stay reachable if a share is live even when the flag later flips.
  const showShareRow = offerShare || sharePhase !== 'idle';

  // ── Rooms state ───────────────────────────────────────────────────────────
  const roomsOn = !!rooms && roomsAvailable(isEnabled, session);
  const awayFromMain = !!rooms && showsBackToMain(rooms.state);
  const inRoomView = !!rooms && rooms.state.kind !== 'main';

  const participants = session.participants || [];
  // In a room the bubbles are who is actually in that room's meeting (Chime
  // presence); in the main session they are the server participant list.
  const roster = awayFromMain && rooms.state.kind === 'inRoom' ? (meetingPresence || []) : participants;
  const ordered = [
    ...roster.filter(id => id === user?.user_id),
    ...roster.filter(id => id !== user?.user_id),
  ];
  // The caller is always shown first even if the roster has not caught up yet.
  if (user?.user_id && !ordered.includes(user.user_id)) ordered.unshift(user.user_id);
  const prompts = Array.isArray(session.prompts) ? session.prompts : [];
  const names = { ...(fetchedNames || {}), ...(rooms?.seedNames || {}) };
  const nameOf = uid => resolveName(uid, { user, friends, fetched: names });

  const contentKind = contentAreaKind({ promptsOpen, hasRemoteShare: !!remoteShare, sharingSelf });
  const topRow = callLayoutMode({ promptsOpen, hasShare: !!remoteShare || sharingSelf }) === 'row';
  const sharerName = remoteShare ? (nameOf(remoteShare.sharerId) || 'Someone') : null;

  // The enlarged share only exists while the share tile is what the content
  // area shows (derived, so a stopped share never leaves a blank stage).
  const shareMax = shareMaximized && contentKind === 'remoteShare';

  // Announce share start/stop to assistive tech. If the share was enlarged when
  // it ended, the view has already returned to everyone: say so.
  const prevSharer = useRef(null);
  const prevShareMax = useRef(false);
  useEffect(() => {
    const prev = prevSharer.current;
    prevSharer.current = sharerName;
    if (sharerName && !prev) setLiveText(`${sharerName} started sharing`);
    else if (!sharerName && prev) {
      setLiveText(`${prev} stopped sharing${prevShareMax.current ? '. Back to everyone.' : ''}`);
    }
  }, [sharerName]);
  // Declared after the effect above so it still sees the previous render's value there.
  useEffect(() => { prevShareMax.current = shareMax; }, [shareMax]);
  // Drop the stored flag once the share is gone so it cannot leak into the next share.
  useEffect(() => { if (!remoteShare && shareMaximized) setShareMaximized(false); }, [remoteShare, shareMaximized]);

  const closeMenu = useCallback((returnFocus = true) => {
    setMenuOpen(false);
    if (returnFocus) btnRef.current?.focus();
  }, []);

  useEffect(() => {
    if (!menuOpen) return undefined;
    menuRef.current?.querySelector('[role="menuitem"]')?.focus();
    const onKey = e => {
      if (e.key === 'Escape') { e.stopPropagation(); closeMenu(); }
    };
    const onDown = e => {
      if (menuRef.current?.contains(e.target) || btnRef.current?.contains(e.target)) return;
      closeMenu(false);
    };
    document.addEventListener('keydown', onKey);
    document.addEventListener('mousedown', onDown);
    return () => {
      document.removeEventListener('keydown', onKey);
      document.removeEventListener('mousedown', onDown);
    };
  }, [menuOpen, closeMenu]);

  const onMenuKey = e => {
    if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
    const items = Array.from(menuRef.current?.querySelectorAll('[role="menuitem"]') || []);
    if (!items.length) return;
    e.preventDefault();
    const i = items.indexOf(document.activeElement);
    const next = e.key === 'ArrowDown' ? (i + 1) % items.length : (i - 1 + items.length) % items.length;
    items[next].focus();
  };

  const item = (key, icon, label, onClick, extra = {}) => (
    <button key={key} type="button" role="menuitem" className="call-menu-item" onClick={onClick} {...extra}>
      <span className="call-menu-icon" aria-hidden="true">{icon}</span>
      <span>{label}</span>
    </button>
  );

  // Share screen row: Share screen / Starting / Stop sharing (error tint) /
  // disabled with "<Name> is sharing" while someone else shares.
  const shareRow = () => {
    if (!showShareRow) return null;
    if (sharingSelf) {
      return (
        <button key="share" type="button" role="menuitem" className="call-menu-item call-menu-item-danger"
          onClick={() => { closeMenu(); screenShare.stop(); }}>
          <span className="call-menu-icon" aria-hidden="true"><DesktopOutlined /></span>
          <span>Stop sharing</span>
        </button>
      );
    }
    if (remoteShare || sharePhase === 'starting') {
      const caption = remoteShare ? `${sharerName} is sharing` : 'Starting…';
      return (
        <button key="share" type="button" role="menuitem" className="call-menu-item" aria-disabled="true" onClick={e => e.preventDefault()}>
          <span className="call-menu-icon" aria-hidden="true"><DesktopOutlined /></span>
          <span className="call-menu-text">
            <span>Share screen</span>
            <span className="call-menu-caption">{caption}</span>
          </span>
        </button>
      );
    }
    return item('share', <DesktopOutlined />, 'Share screen', () => { closeMenu(); screenShare.start(); });
  };

  const closeRooms = () => { setRoomsOpen(false); btnRef.current?.focus(); };
  const roomName = stateRoomName(rooms?.state || { kind: 'main' });
  const notice = screenShare?.notice || rooms?.notice || null;
  const dismissNotice = () => { screenShare?.clearNotice?.(); rooms?.clearNotice?.(); };
  const live = [liveText, rooms?.announcement].filter(Boolean).join('. ');
  // Consent banner: informational and persistent while the MAIN call is being
  // transcribed (a discussion room is a separate meeting and is not).
  const showTranscriptBanner = !!transcriptionActive && !inRoomView;

  return (
    <div className="call-screen">
      <div className="visually-hidden" role="status" aria-live="polite">{live}</div>

      {(sharingSelf || inRoomView || notice || showTranscriptBanner) && (
        <div className="call-status-stack">
          {showTranscriptBanner && (
            <div className="call-transcript-banner" role="status">
              <AudioOutlined aria-hidden="true" />
              <span>{TRANSCRIPT_CONSENT_COPY}</span>
            </div>
          )}
          {sharingSelf && <SharePill onStop={screenShare.stop} />}
          {inRoomView && rooms.state.kind !== 'returnFailed' && (
            <div className="call-room-row">
              <span className="call-room-chip"><TeamOutlined aria-hidden="true" /> {roomName || 'Room'}</span>
              <button
                type="button"
                className="call-backmain-pill"
                disabled={isBusy(rooms.state)}
                aria-label="Back to main session"
                onClick={() => rooms.returnToMain()}
              >
                <RollbackOutlined aria-hidden="true" />
                <span>{rooms.state.kind === 'returning' ? 'Returning…' : 'Back to main'}</span>
              </button>
            </div>
          )}
          {inRoomView && rooms.state.kind === 'returnFailed' && (
            <div className="call-room-failed" role="alert">
              <span>{ROOM_COPY.returnFailed}</span>
              <div className="call-room-failed-actions">
                <button type="button" className="call-room-try" onClick={() => rooms.returnToMain()}>Try again</button>
                <button type="button" className="call-room-end" onClick={onLeave}>End call</button>
              </div>
            </div>
          )}
          <CallNotice text={notice} onDismiss={dismissNotice} />
        </div>
      )}

      <div className="call-stage">
        <div
          className={topRow ? 'call-bubbles call-bubbles-row' : 'call-bubbles call-bubbles-scatter'}
          role="list"
          aria-label="Participants"
        >
          {ordered.map((uid, idx) => {
            const isYou = uid === user?.user_id;
            const name = nameOf(uid);
            return (
              <div role="listitem" key={uid} style={{ display: 'contents' }}>
                <Bubble
                  name={name}
                  userId={uid}
                  isYou={isYou}
                  talking={talkingUserId === uid}
                  compact={topRow}
                  style={topRow ? undefined : { marginTop: SCATTER_OFFSETS[idx % SCATTER_OFFSETS.length] }}
                />
              </div>
            );
          })}
        </div>
        {/* A share wins the content area over Prompts; Prompts return when it stops. */}
        {contentKind === 'remoteShare' && (
          <RemoteShareTile
            tileId={remoteShare.tileId}
            name={sharerName}
            bindVideoTile={bindVideoTile}
            maximized={shareMax}
            onToggle={() => setShareMaximized(m => !m)}
          />
        )}
        {contentKind === 'selfShare' && <YourSharePanel onStop={screenShare.stop} />}
        {contentKind === 'prompts' && <PromptsPanel prompts={prompts} onClose={() => setPromptsOpen(false)} />}
      </div>

      <div className="call-dock">
        <button type="button" className="call-dock-btn call-end-btn" aria-label="End call" onClick={onLeave}>
          <PhoneOutlined rotate={135} aria-hidden="true" />
        </button>
        <div className="call-interactions-wrap">
          {menuOpen && (
            <div
              ref={menuRef}
              id="call-interactions-menu"
              className="call-menu"
              role="menu"
              aria-label="Interactions"
              onKeyDown={onMenuKey}
            >
              {canRing && item('ring', <BellOutlined />, 'Ring', () => { closeMenu(); onRing(); })}
              {shareRow()}
              {item('prompts', <CommentOutlined />, promptsOpen ? 'Hide prompts' : 'Prompts', () => { setPromptsOpen(o => !o); closeMenu(); })}
              {roomsOn && item('rooms', <TeamOutlined />, 'Rooms', () => { setMenuOpen(false); setRoomsOpen(true); })}
              {item('camera', <VideoCameraOutlined />, videoEnabled ? 'Turn off camera' : 'Turn on camera', () => { closeMenu(); onToggleVideo?.(); })}
              {item('mute', muted ? <AudioOutlined /> : <AudioMutedOutlined />, muted ? 'Unmute' : 'Mute', () => { closeMenu(); onToggleMute?.(); })}
            </div>
          )}
          <button
            ref={btnRef}
            type="button"
            className={`call-dock-btn call-interactions-btn${menuOpen ? ' call-interactions-btn-open' : ''}`}
            aria-label={muted ? 'Interactions, muted' : 'Interactions'}
            aria-haspopup="menu"
            aria-expanded={menuOpen}
            aria-controls="call-interactions-menu"
            onClick={() => (menuOpen ? closeMenu(false) : setMenuOpen(true))}
          >
            {menuOpen ? <CloseOutlined aria-hidden="true" /> : <EllipsisOutlined aria-hidden="true" />}
            {muted && (
              <span className="call-muted-badge" aria-hidden="true"><AudioMutedOutlined /></span>
            )}
          </button>
        </div>
      </div>

      {roomsOn && roomsOpen && (
        <SessionRoomsModal
          open={roomsOpen}
          onClose={closeRooms}
          session={session}
          user={user}
          rooms={rooms}
          inviteCandidates={inviteCandidates}
        />
      )}
    </div>
  );
}
