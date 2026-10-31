import React, { useCallback, useEffect, useRef, useState } from 'react';
import ProfileLink from './profile/ProfileLink.jsx';
import { Avatar, Button, Modal, Typography, ConfigProvider } from 'antd';
import { formTheme } from '../lib/formTokens.js';
import { AudioOutlined, AudioMutedOutlined, PhoneOutlined, EditOutlined, DeleteOutlined, CloseOutlined } from '@ant-design/icons';
import { API } from '../config.js';
import { useJoinWindow } from '../hooks/useJoinWindow.js';
import { isSessionHost, JOIN_GRACE_MINUTES } from '../lib/sessionAccess.js';
import RingMembersModal from './RingMembersModal.jsx';
import { MaxBackButton, useEscapeToClose } from './CallMaximize.jsx';
import SessionCallScreen, { resolveName } from './SessionCallScreen.jsx';

const { Text } = Typography;

function parseVerseRef(ref) {
  const parts = ref.split('-');
  if (parts.length < 3) return { label: ref, book: '', ch: 0, vs: 0 };
  const vs   = parseInt(parts[parts.length - 1]);
  const ch   = parseInt(parts[parts.length - 2]);
  const book = parts.slice(0, parts.length - 2).join(' ');
  return { label: `${book} ${ch}:${vs}`, book, ch, vs };
}

function formatTime(isoStr) {
  if (!isoStr) return '';
  return new Date(isoStr).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function useUsernames(participantIds) {
  const [names, setNames] = useState({});
  useEffect(() => {
    participantIds.forEach(async uid => {
      if (names[uid]) return;
      try {
        const res = await fetch(`${API}/user/${uid}`);
        if (res.ok) {
          const d = await res.json();
          if (d.username) setNames(prev => ({ ...prev, [uid]: d.username }));
        }
      } catch {}
    });
  }, [participantIds.join(',')]);
  return names;
}

// Shared island wrapper
const islandStyle = {
  margin: '0.6rem 0.75rem 0.2rem',
  borderRadius: '10px',
  border: '1px solid rgba(255,255,255,0.132)',
  background: 'rgba(18,13,5,0.85)',
  boxShadow: '0 2px 12px rgba(0,0,0,0.4), inset 0 1px 0 rgba(255,198,26,0.08)',
  overflow: 'hidden',
  flexShrink: 0,
};

function IconBtn({ icon, onClick, title, danger, active }) {
  const base  = danger ? 'rgba(255,90,90,0.55)' : active ? 'var(--gold)' : 'rgba(255,198,26,0.4)';
  const hover = danger ? 'rgba(255,90,90,0.9)'  : 'rgba(255,198,26,0.85)';
  return (
    <button
      title={title}
      onClick={onClick}
      style={{
        background: 'none', border: 'none', cursor: 'pointer',
        color: base, fontSize: '0.7rem', padding: '2px 4px',
        transition: 'color 0.15s',
      }}
      onMouseEnter={e => { e.currentTarget.style.color = hover; }}
      onMouseLeave={e => { e.currentTarget.style.color = base; }}
    >
      {icon}
    </button>
  );
}

function VideoTile({ tileId, isLocal, bindVideoTile, fit = 'cover', fill = false }) {
  const refCallback = useCallback(el => {
    if (el) bindVideoTile(tileId, el);
  }, [tileId, bindVideoTile]);

  return (
    <video
      ref={refCallback}
      autoPlay
      playsInline
      muted
      style={{
        width: '100%',
        borderRadius: 6,
        background: '#000',
        display: 'block',
        transform: isLocal ? 'scaleX(-1)' : 'none',
        aspectRatio: fill ? undefined : '16 / 9',
        height: fill ? '100%' : undefined,
        objectFit: fit,
      }}
    />
  );
}

// Shown under a session's Join button once useSessions' joinSession has
// surfaced a { sessionId, message } error for this session (Chime call-join
// used to fail with zero user-visible signal -- Architecture Q27). Retrying
// just calls onJoin again; joinSession() itself clears the stale error at
// the start of the new attempt.
function JoinErrorRow({ session, joinError, onJoin, onClearJoinError }) {
  if (!joinError || joinError.sessionId !== session.id) return null;
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: '0.4rem', marginTop: '0.35rem', flexWrap: 'wrap' }}>
      <Text style={{ fontSize: '0.62rem', color: 'rgba(255,120,120,0.85)', fontFamily: 'inherit' }}>
        {joinError.message}
      </Text>
      <Button
        size="small" onClick={() => onJoin(session.id)}
        style={{ fontSize: '0.6rem', height: 18, padding: '0 6px', background: 'rgba(255,198,26,0.7)', borderColor: 'transparent', color: '#fff' }}
      >
        Retry
      </Button>
      <IconBtn icon={<CloseOutlined />} title="Dismiss" onClick={onClearJoinError} />
    </div>
  );
}

// Join is only enabled inside the join window (grace minutes before start until
// the end). Disabled state is announced (aria-label) and explained (title).
// Server stays authoritative; this only prevents a pointless failing request.
function JoinButton({ session, onJoin }) {
  const open = useJoinWindow(session);
  return (
    <Button
      size="small"
      disabled={!open}
      onClick={() => onJoin(session.id)}
      aria-label={open ? `Join ${session.title}` : `Join ${session.title}, not open yet`}
      title={open ? undefined : `Opens ${JOIN_GRACE_MINUTES} minutes before the start time`}
      style={open
        ? { fontSize: '0.62rem', height: 20, padding: '0 7px', background: 'rgba(255,198,26,0.7)', borderColor: 'transparent', color: '#fff' }
        : { fontSize: '0.62rem', height: 20, padding: '0 7px' }}
    >
      Join
    </Button>
  );
}

// Host-only Edit and Delete. Delete asks first (iOS "Delete Session?" alert):
// the server delete is permanent. Renders nothing for non-hosts or when
// creator_id is missing (fail closed).
function HostControls({ session, user, onEdit, onDelete }) {
  const [confirming, setConfirming] = useState(false);
  if (!isSessionHost(session, user)) return null;
  return (
    <>
      <IconBtn icon={<EditOutlined />} title="Edit session" onClick={() => onEdit(session)} />
      <IconBtn icon={<DeleteOutlined />} title="Delete session" onClick={() => setConfirming(true)} danger />
      <ConfigProvider theme={formTheme}>
<Modal
        open={confirming}
        title="Delete Session?"
        okText="Delete"
        okButtonProps={{ danger: true }}
        cancelText="Cancel"
        onOk={() => { setConfirming(false); onDelete(session.id); }}
        onCancel={() => setConfirming(false)}
        centered
        destroyOnHidden
        width="min(420px, calc(100vw - 32px))"
      >
        <p style={{ margin: 0 }}>
          This permanently deletes &quot;{session.title}&quot; for everyone. This can&apos;t be undone.
        </p>
      </Modal>
</ConfigProvider>
    </>
  );
}

export function UpcomingCard({ session, user, activeSessionId, onJoin, onLeave, onEdit, onDelete, joinError, onClearJoinError }) {
  const isJoined = activeSessionId === session.id;
  return (
    <div style={islandStyle}>
      <div style={{ padding: '0.55rem 0.75rem' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.55rem' }}>
          <PhoneOutlined style={{ fontSize: '0.8rem', color: 'rgba(255,198,26,0.45)', flexShrink: 0 }} />
          <div style={{ flex: 1, minWidth: 0 }}>
            <Text style={{ display: 'block', fontFamily: 'inherit', fontSize: '0.78rem', color: 'var(--parchment)', lineHeight: 1.3 }}>
              {session.title}
            </Text>
            <Text style={{ fontSize: '0.62rem', color: 'rgba(242,242,242,0.4)', fontFamily: 'inherit' }}>
              {formatTime(session.time_start)}
              {session.time_end ? ` – ${formatTime(session.time_end)}` : ''}
              {session.recurring && <span style={{ marginLeft: '0.4rem', color: 'rgba(255,198,26,0.55)' }}>· Weekly</span>}
            </Text>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.25rem', flexShrink: 0 }}>
            {isJoined ? (
              <Button
                size="small" danger onClick={onLeave}
                style={{ fontSize: '0.62rem', height: 20, padding: '0 7px' }}
              >
                Leave
              </Button>
            ) : (
              <JoinButton session={session} onJoin={onJoin} />
            )}
            <HostControls session={session} user={user} onEdit={onEdit} onDelete={onDelete} />
          </div>
        </div>
        <JoinErrorRow session={session} joinError={joinError} onJoin={onJoin} onClearJoinError={onClearJoinError} />
      </div>
    </div>
  );
}

export function ActiveCard({ session, user, ringCandidates, friends, muted = false, onToggleMute, activeSessionId, talkingUserId, onJoin, onLeave, onEdit, onDelete, onNavigateVerse, videoEnabled, videoTiles = [], onToggleVideo, bindVideoTile, joinError, onClearJoinError }) {
  const isJoined = activeSessionId === session.id;
  const names    = useUsernames(session.participants || []);
  // Ring members (task 20261003-web-reader-ios-parity): only while joined.
  // sentRing remembers who was rung during this call across modal reopenings.
  const [ringOpen, setRingOpen] = useState(false);
  const sentRing = useRef(new Set());
  // Names come from the signed-in user, friends, then a fetched lookup. Unknown
  // stays null so the UI shows a neutral glyph, never a raw id.
  const nameOf = uid => resolveName(uid, { user, friends, fetched: names });
  const talkingName = talkingUserId ? nameOf(talkingUserId) : null;
  const canRing = Array.isArray(ringCandidates) && ringCandidates.length > 0;

  // Tap-to-maximize for camera tiles (task 20261016-call-maximize-tiles). Local
  // only; holds a snapshot of the tile so a leave / camera-off can be announced
  // after the tile itself is gone. The tile's <video> moves into the overlay
  // (one binding at a time) and back to the strip on return.
  const cardRef = useRef(null);
  const [maxTile, setMaxTile] = useState(null);
  const [liveText, setLiveText] = useState('');
  const restoreFocusId = useRef(null);
  const tileName = tile => (tile.isLocal ? 'You' : (tile.userId ? nameOf(tile.userId) : null));
  const closeMax = () => { restoreFocusId.current = maxTile?.tileId ?? null; setMaxTile(null); };
  useEscapeToClose(!!maxTile, closeMax);
  useEffect(() => {
    if (maxTile || restoreFocusId.current == null) return;
    const id = restoreFocusId.current;
    restoreFocusId.current = null;
    cardRef.current?.querySelector(`[data-call-tile="${id}"]`)?.focus();
  }, [maxTile]);
  // Auto-restore: the enlarged tile vanished (participant left, camera off,
  // own camera off) or the call ended. Cleared in the render pass that sees it.
  const maxStillThere = !!maxTile && isJoined && videoTiles.some(t => t.tileId === maxTile.tileId);
  useEffect(() => {
    if (!maxTile || maxStillThere) return;
    setMaxTile(null);
    if (!isJoined) { setLiveText(''); return; }
    const gone = !maxTile.isLocal && maxTile.userId && !(session.participants || []).includes(maxTile.userId);
    const who = maxTile.isLocal ? null : maxTile.name;
    if (maxTile.isLocal) setLiveText('Your camera is off. Back to everyone.');
    else if (who && gone) setLiveText(`${who} left the call. Back to everyone.`);
    else if (who) setLiveText(`${who} turned their camera off. Back to everyone.`);
    else setLiveText('Back to everyone.');
  }, [maxTile, maxStillThere, isJoined, session.participants]);
  const shownMax = maxStillThere ? videoTiles.find(t => t.tileId === maxTile.tileId) : null;
  const shownMaxName = shownMax ? tileName(shownMax) : null;

  return (
    <div ref={cardRef} className={isJoined ? 'call-card' : undefined} style={isJoined ? { ...islandStyle, background: undefined, position: 'relative' } : islandStyle}>
      {isJoined && <div className="visually-hidden" role="status" aria-live="polite">{liveText}</div>}
      <div style={{ padding: '0.6rem 0.75rem' }}>

        {/* Row 1: title + controls */}
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '0.4rem' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', minWidth: 0 }}>
            <Text style={{ fontFamily: 'inherit', fontSize: '0.82rem', color: 'var(--parchment)', fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {session.title}
            </Text>
            <HostControls session={session} user={user} onEdit={onEdit} onDelete={onDelete} />
          </div>

          <div style={{ display: 'flex', alignItems: 'center', gap: '0.4rem', flexShrink: 0 }}>
            {isJoined && muted && (
              <span className="call-muted-pill" role="status">
                <AudioMutedOutlined aria-hidden="true" /> Muted
              </span>
            )}
            {isJoined && talkingName && (
              <span style={{ display: 'flex', alignItems: 'center', gap: '0.22rem', fontSize: '0.62rem', color: 'var(--gold)' }}>
                <AudioOutlined />
                {talkingName}
              </span>
            )}
            {!isJoined && <JoinButton session={session} onJoin={onJoin} />}
          </div>
        </div>

        <JoinErrorRow session={session} joinError={joinError} onJoin={onJoin} onClearJoinError={onClearJoinError} />

        {isJoined && (
          <RingMembersModal
            open={ringOpen}
            onClose={() => setRingOpen(false)}
            session={session}
            user={user}
            candidates={ringCandidates}
            sentRef={sentRing}
          />
        )}

        {/* Row 1b: time + recurring */}
        <div style={{ marginBottom: '0.35rem' }}>
          <Text style={{ fontSize: '0.6rem', color: 'rgba(242,242,242,0.35)', fontFamily: 'inherit' }}>
            {formatTime(session.time_start)}
            {session.time_end ? ` – ${formatTime(session.time_end)}` : ''}
            {session.recurring && <span style={{ marginLeft: '0.4rem', color: 'rgba(255,198,26,0.5)' }}>· Weekly</span>}
          </Text>
        </div>

        {/* Row 2: participants (call screen shows bubbles instead once joined) */}
        {!isJoined && <div style={{ display: 'flex', alignItems: 'center', gap: '0.22rem', marginBottom: (session.verses || []).length ? '0.4rem' : 0, flexWrap: 'wrap' }}>
          {(session.participants || []).length === 0 ? (
            <Text style={{ fontSize: '0.6rem', color: 'rgba(242,242,242,0.25)', fontFamily: 'inherit', fontStyle: 'italic' }}>
              No one has joined yet
            </Text>
          ) : (
            (session.participants || []).map(uid => {
              const name     = nameOf(uid) || 'Member';
              const isTalking = talkingUserId === uid;
              return (
                <div key={uid} title={name} style={{ position: 'relative' }}>
                  <ProfileLink userId={uid} username={nameOf(uid)} style={{ minWidth: 0, minHeight: 0, display: 'inline-flex' }}>
                  <Avatar
                    size={20}
                    style={{
                      background: isTalking ? 'rgba(255,198,26,0.55)' : 'rgba(255,198,26,0.14)',
                      border: `1px solid ${isTalking ? 'var(--gold)' : 'rgba(255,255,255,0.168)'}`,
                      color: 'var(--gold)', fontSize: '0.5rem',
                      transition: 'background 0.2s, border-color 0.2s',
                    }}
                  >
                    {name[0]?.toUpperCase()}
                  </Avatar>
                  </ProfileLink>
                  {isTalking && (
                    <span style={{
                      position: 'absolute', bottom: -1, right: -1,
                      width: 6, height: 6, borderRadius: '50%',
                      background: 'var(--gold)', border: '1px solid var(--bg)',
                    }} />
                  )}
                </div>
              );
            })
          )}
        </div>}

        {isJoined && (
          <SessionCallScreen
            session={session}
            user={user}
            friends={friends}
            fetchedNames={names}
            talkingUserId={talkingUserId}
            muted={muted}
            onToggleMute={onToggleMute}
            videoEnabled={videoEnabled}
            onToggleVideo={onToggleVideo}
            canRing={canRing}
            inviteCandidates={ringCandidates}
            onRing={() => setRingOpen(true)}
            onLeave={onLeave}
          />
        )}

        {/* Row 2b: live video tiles */}
        {isJoined && videoTiles.length > 0 && (
          <div style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fill, minmax(110px, 1fr))',
            gap: '0.3rem',
            marginBottom: '0.4rem',
          }}>
            {videoTiles.map(tile => {
              const name = tileName(tile);
              const label = tile.isLocal ? 'Enlarge your video' : (name ? `Enlarge ${name}'s video` : 'Enlarge video');
              if (maxTile?.tileId === tile.tileId) {
                return <div key={tile.tileId} className="call-vtile-away" aria-hidden="true" />;
              }
              return (
                <button
                  key={tile.tileId}
                  type="button"
                  className="call-vtile-btn"
                  data-call-tile={tile.tileId}
                  aria-label={label}
                  onClick={() => setMaxTile({ tileId: tile.tileId, isLocal: !!tile.isLocal, userId: tile.userId || '', name: name && !tile.isLocal ? name : null })}
                >
                  <VideoTile tileId={tile.tileId} isLocal={tile.isLocal} bindVideoTile={bindVideoTile} />
                </button>
              );
            })}
          </div>
        )}

        {shownMax && (
          <div
            className="call-max-overlay"
            role="region"
            aria-label={shownMaxName && !shownMax.isLocal ? `${shownMaxName}, enlarged video` : (shownMax.isLocal ? 'Your enlarged video' : 'Enlarged video')}
          >
            <MaxBackButton onClick={closeMax} />
            <button type="button" className="call-max-surface" aria-label="Return to everyone" onClick={closeMax}>
              <VideoTile tileId={shownMax.tileId} isLocal={shownMax.isLocal} bindVideoTile={bindVideoTile} fit="contain" fill />
            </button>
            {shownMaxName && <span className="call-max-name">{shownMaxName}</span>}
          </div>
        )}

        {/* Row 3: verse links */}
        {(session.verses || []).length > 0 && (
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.28rem', marginBottom: 0 }}>
            {(session.verses || []).map(ref => {
              const { label, book, ch, vs } = parseVerseRef(ref);
              return (
                <button
                  key={ref}
                  onClick={() => onNavigateVerse(book, ch, vs)}
                  style={{
                    background: 'none', border: '1px solid rgba(255,255,255,0.108)',
                    borderRadius: 3, padding: '0.08rem 0.35rem',
                    cursor: 'pointer', fontSize: '0.6rem',
                    color: 'rgba(255,198,26,0.7)', fontFamily: 'inherit',
                    transition: 'border-color 0.15s, color 0.15s',
                  }}
                  onMouseEnter={e => { e.currentTarget.style.borderColor = 'rgba(255,255,255,0.33)'; e.currentTarget.style.color = 'var(--gold)'; }}
                  onMouseLeave={e => { e.currentTarget.style.borderColor = 'rgba(255,255,255,0.108)'; e.currentTarget.style.color = 'rgba(255,198,26,0.7)'; }}
                >
                  {label}
                </button>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}

// Picks the card variant the same way SessionWidget always has: started
// sessions get the full ActiveCard, future ones the compact UpcomingCard.
export function SessionCard(props) {
  const { session } = props;
  const started = session.time_start && new Date(session.time_start).getTime() <= Date.now();
  // A session joined inside the early-join grace window is already live, so it
  // gets the full card (call controls, Ring) even before time_start.
  const joined = props.activeSessionId === session.id;
  return (started || joined) ? <ActiveCard {...props} /> : <UpcomingCard {...props} />;
}

export default function SessionWidget({
  sessions, user, activeSessionId, talkingUserId,
  onJoin, onLeave, onEdit, onDelete, onNavigateVerse,
  videoEnabled, videoTiles, onToggleVideo, bindVideoTile,
  muted, onToggleMute, friends, ringCandidates,
  joinError, onClearJoinError,
}) {
  if (!sessions || sessions.length === 0) return null;

  const now = Date.now();

  const visible = sessions.filter(s => {
    // Hide sessions whose end time has passed AND nobody is in them
    if (s.time_end) {
      const ended = new Date(s.time_end).getTime() <= now;
      if (ended && (s.participants || []).length === 0) return false;
    }
    return true;
  });

  if (visible.length === 0) return null;

  return (
    <>
      {visible.map(session => {
        const started = session.time_start && new Date(session.time_start).getTime() <= now;
        return started ? (
          <ActiveCard
            key={session.id}
            session={session}
            user={user}
            activeSessionId={activeSessionId}
            talkingUserId={talkingUserId}
            onJoin={onJoin}
            onLeave={onLeave}
            onEdit={onEdit}
            onDelete={onDelete}
            onNavigateVerse={onNavigateVerse}
            videoEnabled={videoEnabled}
            videoTiles={videoTiles}
            onToggleVideo={onToggleVideo}
            bindVideoTile={bindVideoTile}
            muted={muted}
            onToggleMute={onToggleMute}
            friends={friends}
            ringCandidates={ringCandidates}
            joinError={joinError}
            onClearJoinError={onClearJoinError}
          />
        ) : (
          <UpcomingCard
            key={session.id}
            session={session}
            user={user}
            activeSessionId={activeSessionId}
            onJoin={onJoin}
            onLeave={onLeave}
            onEdit={onEdit}
            onDelete={onDelete}
            joinError={joinError}
            onClearJoinError={onClearJoinError}
          />
        );
      })}
    </>
  );
}
