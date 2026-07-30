import React, { useState, useEffect, useRef } from 'react';
import { Button, Avatar, Typography, Input } from 'antd';
import { SendOutlined, ArrowLeftOutlined, TeamOutlined } from '@ant-design/icons';
import SessionWidget from './SessionWidget.jsx';

const { Text } = Typography;

// ── Chat thread (iMessage style) ──────────────────────────────────────────────

export default function ChatThread({
  contact, messages, groupMembers, user, onBack, onSend,
  sessions, activeSessionId, talkingUserId,
  onJoinSession, onLeaveSession, onOpenSessionCreator,
  onEditSession, onDeleteSession, onNavigateVerse,
  videoEnabled, videoTiles, onToggleVideo, bindVideoTile,
}) {
  const [text, setText]               = useState('');
  const [showMembers, setShowMembers] = useState(false);
  const endRef = useRef(null);

  useEffect(() => { endRef.current?.scrollIntoView({ behavior: 'smooth' }); }, [messages]);

  const handleSend = () => {
    if (!text.trim()) return;
    onSend(text.trim());
    setText('');
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', overflow: 'hidden' }}>
      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem', padding: '0.8rem 1rem', borderBottom: '1px solid rgba(200,134,26,0.15)', flexShrink: 0 }}>
        <Button type="text" icon={<ArrowLeftOutlined />} onClick={onBack}
          style={{ color: 'rgba(200,134,26,0.65)', padding: '0 4px' }} />
        <Text
          strong
          style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.88rem', color: 'var(--parchment)', flex: 1, cursor: contact?.type === 'group' ? 'pointer' : 'default' }}
          onClick={() => contact?.type === 'group' && setShowMembers(v => !v)}
        >
          {contact?.name}
          {contact?.type === 'group' && <TeamOutlined style={{ marginLeft: 6, fontSize: '0.72rem', color: 'rgba(200,134,26,0.5)' }} />}
        </Text>
        <button
          onClick={onOpenSessionCreator}
          style={{
            background: 'rgba(200,134,26,0.08)',
            border: 'none',
            borderRadius: 6,
            color: 'rgba(200,134,26,0.75)',
            cursor: 'pointer',
            fontSize: '0.62rem',
            letterSpacing: '0.06em',
            fontFamily: "'Inter', sans-serif",
            padding: '0.22rem 0.55rem',
            whiteSpace: 'nowrap',
            transition: 'background 0.15s, border-color 0.15s, color 0.15s',
          }}
          onMouseEnter={e => { e.currentTarget.style.background = 'rgba(200,134,26,0.16)'; e.currentTarget.style.borderColor = 'rgba(200,134,26,0.55)'; e.currentTarget.style.color = 'var(--gold)'; }}
          onMouseLeave={e => { e.currentTarget.style.background = 'rgba(200,134,26,0.08)'; e.currentTarget.style.borderColor = 'rgba(200,134,26,0.28)'; e.currentTarget.style.color = 'rgba(200,134,26,0.75)'; }}
        >
          + Session
        </button>
      </div>

      {/* Session island widgets */}
      <SessionWidget
        sessions={sessions}
        user={user}
        activeSessionId={activeSessionId}
        talkingUserId={talkingUserId}
        onJoin={onJoinSession}
        onLeave={onLeaveSession}
        onEdit={onEditSession}
        onDelete={onDeleteSession}
        onNavigateVerse={onNavigateVerse}
        videoEnabled={videoEnabled}
        videoTiles={videoTiles}
        onToggleVideo={onToggleVideo}
        bindVideoTile={bindVideoTile}
      />

      {/* Group members panel */}
      {showMembers && contact?.type === 'group' && (
        <div style={{ padding: '0.7rem 1rem', borderBottom: '1px solid rgba(200,134,26,0.12)', background: 'rgba(200,134,26,0.04)', maxHeight: 160, overflowY: 'auto', flexShrink: 0 }}>
          <Text style={{ fontSize: '0.55rem', letterSpacing: '0.18em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.45)', display: 'block', marginBottom: '0.4rem' }}>Members</Text>
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.45rem', marginBottom: '0.3rem' }}>
            <Avatar size={22} style={{ background: 'rgba(200,134,26,0.12)', border: 'none', color: 'var(--gold)', fontSize: '0.55rem' }}>
              {(user?.username || 'Y')[0].toUpperCase()}
            </Avatar>
            <Text style={{ fontSize: '0.72rem', color: 'var(--gold)', fontFamily: "'Inter', sans-serif" }}>{user?.username} (you)</Text>
          </div>
          {groupMembers.map((m, i) => {
            const uname = m.username || m.user_id?.slice(0, 8) || '?';
            return (
              <div key={i} style={{ display: 'flex', alignItems: 'center', gap: '0.45rem', marginBottom: '0.3rem' }}>
                <Avatar size={22} style={{ background: 'rgba(200,134,26,0.12)', border: 'none', color: 'var(--gold)', fontSize: '0.55rem' }}>
                  {uname[0].toUpperCase()}
                </Avatar>
                <Text style={{ fontSize: '0.72rem', color: 'rgba(244,228,193,0.65)', fontFamily: "'Inter', sans-serif" }}>{uname}</Text>
              </div>
            );
          })}
        </div>
      )}

      {/* Messages */}
      <div style={{ flex: 1, overflowY: 'auto', padding: '0.75rem 0.85rem', display: 'flex', flexDirection: 'column', gap: '0.45rem' }}>
        {messages.length === 0 && (
          <div style={{ textAlign: 'center', padding: '2rem 1rem' }}>
            <Text style={{ fontSize: '0.72rem', color: 'rgba(244,228,193,0.22)', fontFamily: "'Inter', sans-serif" }}>No messages yet. Say hello!</Text>
          </div>
        )}
        {messages.map((m, i) => (
          <div key={i} className={`msg-bubble ${m.mine ? 'sent' : 'received'}`}>
            {!m.mine && m.sender && <div className="msg-bubble-sender">{m.sender}</div>}
            {m.text}
            {m.timestamp && (
              <div className="msg-bubble-meta">
                {new Date(m.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
              </div>
            )}
          </div>
        ))}
        <div ref={endRef} />
      </div>

      {/* Input */}
      <div style={{ display: 'flex', gap: '0.4rem', padding: '0.65rem 0.8rem', borderTop: '1px solid rgba(200,134,26,0.15)', flexShrink: 0, alignItems: 'flex-end' }}>
        <Input
          value={text}
          onChange={e => setText(e.target.value)}
          onPressEnter={handleSend}
          placeholder="Message…"
          style={{ flex: 1, borderRadius: 20, fontSize: '0.82rem' }}
        />
        <Button
          type="primary" shape="circle" icon={<SendOutlined />}
          onClick={handleSend}
          disabled={!text.trim()}
          style={{ flexShrink: 0 }}
        />
      </div>
    </div>
  );
}
