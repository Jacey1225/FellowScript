import React, { useEffect, useState } from 'react';
import { Avatar, Button, Typography } from 'antd';
import { AudioOutlined, PhoneOutlined, EditOutlined, DeleteOutlined } from '@ant-design/icons';
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
  }, [participantIds.join(',')]); // eslint-disable-line react-hooks/exhaustive-deps
  return names;
}

// Shared island wrapper
const islandStyle = {
  margin: '0.6rem 0.75rem 0.2rem',
  borderRadius: '10px',
  border: '1px solid rgba(200,134,26,0.22)',
  background: 'rgba(18,13,5,0.85)',
  boxShadow: '0 2px 12px rgba(0,0,0,0.4), inset 0 1px 0 rgba(200,134,26,0.08)',
  overflow: 'hidden',
  flexShrink: 0,
};

function IconBtn({ icon, onClick, title, danger }) {
  return (
    <button
      title={title}
      onClick={onClick}
      style={{
        background: 'none', border: 'none', cursor: 'pointer',
        color: danger ? 'rgba(255,90,90,0.55)' : 'rgba(200,134,26,0.4)',
        fontSize: '0.7rem', padding: '2px 4px',
        transition: 'color 0.15s',
      }}
      onMouseEnter={e => { e.currentTarget.style.color = danger ? 'rgba(255,90,90,0.9)' : 'rgba(200,134,26,0.85)'; }}
      onMouseLeave={e => { e.currentTarget.style.color = danger ? 'rgba(255,90,90,0.55)' : 'rgba(200,134,26,0.4)'; }}
    >
      {icon}
    </button>
  );
}

function UpcomingCard({ session, onEdit, onDelete }) {
  return (
    <div style={islandStyle}>
      <div style={{
        display: 'flex', alignItems: 'center', gap: '0.55rem',
        padding: '0.55rem 0.75rem',
      }}>
        <PhoneOutlined style={{ fontSize: '0.8rem', color: 'rgba(200,134,26,0.45)', flexShrink: 0 }} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <Text style={{ display: 'block', fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'var(--parchment)', lineHeight: 1.3 }}>
            {session.title}
          </Text>
          <Text style={{ fontSize: '0.62rem', color: 'rgba(244,228,193,0.4)', fontFamily: "'Lora', serif" }}>
            {formatTime(session.time_start)}
            {session.time_end ? ` – ${formatTime(session.time_end)}` : ''}
          </Text>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.1rem', flexShrink: 0 }}>
          <IconBtn icon={<EditOutlined />} title="Edit session" onClick={() => onEdit(session)} />
          <IconBtn icon={<DeleteOutlined />} title="Delete session" onClick={() => onDelete(session.id)} danger />
        </div>
      </div>
    </div>
  );
}

function ActiveCard({ session, user, activeSessionId, talkingUserId, onJoin, onLeave, onEdit, onNavigateVerse }) {
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
            <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.82rem', color: 'var(--parchment)', fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {session.title}
            </Text>
            <IconBtn icon={<EditOutlined />} title="Edit session" onClick={() => onEdit(session)} />
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
                style={{ fontSize: '0.62rem', height: 20, padding: '0 7px', background: 'rgba(200,134,26,0.7)', borderColor: 'transparent', color: '#fff' }}
              >
                Join
              </Button>
            )}
          </div>
        </div>

        {/* Row 2: participants */}
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.22rem', marginBottom: (session.verses || []).length ? '0.4rem' : 0, flexWrap: 'wrap' }}>
          {(session.participants || []).length === 0 ? (
            <Text style={{ fontSize: '0.6rem', color: 'rgba(244,228,193,0.25)', fontFamily: "'Lora', serif", fontStyle: 'italic' }}>
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
                      background: isTalking ? 'rgba(200,134,26,0.55)' : 'rgba(200,134,26,0.14)',
                      border: `1px solid ${isTalking ? 'var(--gold)' : 'rgba(200,134,26,0.28)'}`,
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

        {/* Row 3: verse links */}
        {(session.verses || []).length > 0 && (
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.28rem' }}>
            {(session.verses || []).map(ref => {
              const { label, book, ch, vs } = parseVerseRef(ref);
              return (
                <button
                  key={ref}
                  onClick={() => onNavigateVerse(book, ch, vs)}
                  style={{
                    background: 'none', border: '1px solid rgba(200,134,26,0.18)',
                    borderRadius: 3, padding: '0.08rem 0.35rem',
                    cursor: 'pointer', fontSize: '0.6rem',
                    color: 'rgba(200,134,26,0.7)', fontFamily: "'Lora', serif",
                    transition: 'border-color 0.15s, color 0.15s',
                  }}
                  onMouseEnter={e => { e.currentTarget.style.borderColor = 'rgba(200,134,26,0.55)'; e.currentTarget.style.color = 'var(--gold)'; }}
                  onMouseLeave={e => { e.currentTarget.style.borderColor = 'rgba(200,134,26,0.18)'; e.currentTarget.style.color = 'rgba(200,134,26,0.7)'; }}
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

export default function SessionWidget({
  sessions, user, activeSessionId, talkingUserId,
  onJoin, onLeave, onEdit, onDelete, onNavigateVerse,
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
            onNavigateVerse={onNavigateVerse}
          />
        ) : (
          <UpcomingCard
            key={session.id}
            session={session}
            onEdit={onEdit}
            onDelete={onDelete}
          />
        );
      })}
    </>
  );
}
