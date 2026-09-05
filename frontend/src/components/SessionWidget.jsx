import React, { useCallback, useEffect, useState } from 'react';
import { Avatar, Button, Typography } from 'antd';
import { AudioOutlined, PhoneOutlined, EditOutlined, DeleteOutlined, VideoCameraOutlined, CloseOutlined } from '@ant-design/icons';
import { API } from '../config.js';

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
          setNames(prev => ({ ...prev, [uid]: d.username || uid.slice(0, 6) }));
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

function VideoTile({ tileId, isLocal, bindVideoTile }) {
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
        aspectRatio: '16 / 9',
        objectFit: 'cover',
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
      <Text style={{ fontSize: '0.62rem', color: 'rgba(255,120,120,0.85)', fontFamily: "'Inter', sans-serif" }}>
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

function UpcomingCard({ session, activeSessionId, onJoin, onLeave, onEdit, onDelete, joinError, onClearJoinError }) {
  const isJoined = activeSessionId === session.id;
  return (
    <div style={islandStyle}>
      <div style={{ padding: '0.55rem 0.75rem' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.55rem' }}>
          <PhoneOutlined style={{ fontSize: '0.8rem', color: 'rgba(255,198,26,0.45)', flexShrink: 0 }} />
          <div style={{ flex: 1, minWidth: 0 }}>
            <Text style={{ display: 'block', fontFamily: "'Inter', sans-serif", fontSize: '0.78rem', color: 'var(--parchment)', lineHeight: 1.3 }}>
              {session.title}
            </Text>
            <Text style={{ fontSize: '0.62rem', color: 'rgba(242,242,242,0.4)', fontFamily: "'Inter', sans-serif" }}>
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
              <Button
                size="small" onClick={() => onJoin(session.id)}
                style={{ fontSize: '0.62rem', height: 20, padding: '0 7px', background: 'rgba(255,198,26,0.7)', borderColor: 'transparent', color: '#fff' }}
              >
                Join
              </Button>
            )}
            <IconBtn icon={<EditOutlined />} title="Edit session" onClick={() => onEdit(session)} />
            <IconBtn icon={<DeleteOutlined />} title="Delete session" onClick={() => onDelete(session.id)} danger />
          </div>
        </div>
        <JoinErrorRow session={session} joinError={joinError} onJoin={onJoin} onClearJoinError={onClearJoinError} />
      </div>
    </div>
  );
}

function ActiveCard({ session, user, activeSessionId, talkingUserId, onJoin, onLeave, onEdit, onDelete, onNavigateVerse, videoEnabled, videoTiles = [], onToggleVideo, bindVideoTile, joinError, onClearJoinError }) {
  const isJoined = activeSessionId === session.id;
  const names    = useUsernames(session.participants || []);
  const talkingName = talkingUserId
    ? (talkingUserId === user?.user_id ? user?.username : names[talkingUserId] || talkingUserId?.slice(0, 6))
    : null;

  return (
    <div style={islandStyle}>
      <div style={{ padding: '0.6rem 0.75rem' }}>

        {/* Row 1: title + controls */}
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '0.4rem' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.35rem', minWidth: 0 }}>
            <Text style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.82rem', color: 'var(--parchment)', fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {session.title}
            </Text>
            {isJoined && (
              <IconBtn
                icon={<VideoCameraOutlined />}
                title={videoEnabled ? 'Turn off camera' : 'Turn on camera'}
                onClick={onToggleVideo}
                active={videoEnabled}
              />
            )}
            <IconBtn icon={<EditOutlined />} title="Edit session" onClick={() => onEdit(session)} />
            <IconBtn icon={<DeleteOutlined />} title="Delete session" onClick={() => onDelete(session.id)} danger />
          </div>

          <div style={{ display: 'flex', alignItems: 'center', gap: '0.4rem', flexShrink: 0 }}>
            {isJoined && talkingName && (
              <span style={{ display: 'flex', alignItems: 'center', gap: '0.22rem', fontSize: '0.62rem', color: 'var(--gold)' }}>
                <AudioOutlined />
                {talkingName}
              </span>
            )}
            {isJoined ? (
              <Button
                size="small" danger onClick={onLeave}
                style={{ fontSize: '0.62rem', height: 20, padding: '0 7px' }}
              >
                Leave
              </Button>
            ) : (
              <Button
                size="small" onClick={() => onJoin(session.id)}
                style={{ fontSize: '0.62rem', height: 20, padding: '0 7px', background: 'rgba(255,198,26,0.7)', borderColor: 'transparent', color: '#fff' }}
              >
                Join
              </Button>
            )}
          </div>
        </div>

        <JoinErrorRow session={session} joinError={joinError} onJoin={onJoin} onClearJoinError={onClearJoinError} />

        {/* Row 1b: time + recurring */}
        <div style={{ marginBottom: '0.35rem' }}>
          <Text style={{ fontSize: '0.6rem', color: 'rgba(242,242,242,0.35)', fontFamily: "'Inter', sans-serif" }}>
            {formatTime(session.time_start)}
            {session.time_end ? ` – ${formatTime(session.time_end)}` : ''}
            {session.recurring && <span style={{ marginLeft: '0.4rem', color: 'rgba(255,198,26,0.5)' }}>· Weekly</span>}
          </Text>
        </div>

        {/* Row 2: participants */}
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.22rem', marginBottom: (session.verses || []).length ? '0.4rem' : 0, flexWrap: 'wrap' }}>
          {(session.participants || []).length === 0 ? (
            <Text style={{ fontSize: '0.6rem', color: 'rgba(242,242,242,0.25)', fontFamily: "'Inter', sans-serif", fontStyle: 'italic' }}>
              No one has joined yet
            </Text>
          ) : (
            (session.participants || []).map(uid => {
              const name     = uid === user?.user_id ? user?.username : (names[uid] || uid.slice(0, 4));
              const isTalking = talkingUserId === uid;
              return (
                <div key={uid} title={name} style={{ position: 'relative' }}>
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
        </div>

        {/* Row 2b: live video tiles */}
        {isJoined && videoTiles.length > 0 && (
          <div style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fill, minmax(110px, 1fr))',
            gap: '0.3rem',
            marginBottom: '0.4rem',
          }}>
            {videoTiles.map(tile => (
              <VideoTile
                key={tile.tileId}
                tileId={tile.tileId}
                isLocal={tile.isLocal}
                bindVideoTile={bindVideoTile}
              />
            ))}
          </div>
        )}

        {/* Row 3: verse links */}
        {(session.verses || []).length > 0 && (
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.28rem', marginBottom: (isJoined && (session.prompts || []).length) ? '0.5rem' : 0 }}>
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
                    color: 'rgba(255,198,26,0.7)', fontFamily: "'Inter', sans-serif",
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

        {/* Row 4: discussion prompts (only when joined) */}
        {isJoined && (session.prompts || []).length > 0 && (
          <div style={{ marginTop: '0.4rem', paddingTop: '0.4rem', borderTop: '1px solid rgba(255,255,255,0.072)' }}>
            <Text style={{ display: 'block', fontSize: '0.55rem', letterSpacing: '0.2em', textTransform: 'uppercase', color: 'rgba(255,198,26,0.45)', fontFamily: "'Inter', sans-serif", marginBottom: '0.3rem' }}>
              Discussion Prompts
            </Text>
            <ol style={{ margin: 0, padding: '0 0 0 1.1rem', display: 'flex', flexDirection: 'column', gap: '0.28rem' }}>
              {(session.prompts || []).map((p, i) => (
                <li key={i} style={{ fontSize: '0.7rem', color: 'rgba(242,242,242,0.75)', fontFamily: "'Inter', sans-serif", lineHeight: 1.55 }}>
                  {p}
                </li>
              ))}
            </ol>
          </div>
        )}
      </div>
    </div>
  );
}

export default function SessionWidget({
  sessions, user, activeSessionId, talkingUserId,
  onJoin, onLeave, onEdit, onDelete, onNavigateVerse,
  videoEnabled, videoTiles, onToggleVideo, bindVideoTile,
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
            joinError={joinError}
            onClearJoinError={onClearJoinError}
          />
        ) : (
          <UpcomingCard
            key={session.id}
            session={session}
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
