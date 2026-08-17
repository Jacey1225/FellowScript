import React, { useState, useEffect, useRef } from 'react';
import { Input, Button, Typography, Spin, Divider } from 'antd';
import {
  SendOutlined, ArrowLeftOutlined, BookOutlined,
  EditOutlined, CloseOutlined, RobotOutlined,
} from '@ant-design/icons';
import { AgentMessage } from './RichText.jsx';

const { Text } = Typography;

function agentLabel(agent) {
  if (agent?.name) return agent.name;
  if (!agent?.role || agent.role.startsWith('You are a spiritual')) return 'Spiritual Guide';
  const firstLine = agent.role.split('\n').find(l => l.trim());
  return (firstLine || '').slice(0, 26) || 'Agent';
}

// ── Agent chat thread ─────────────────────────────────────────────────────────

export default function AgentChatThread({ agent, messages, user, onBack, onSend, agentThinking, curBook, curChapter, curVerse, allNotes, onNavigateVerse }) {
  const [text,           setText]           = useState('');
  const [context,        setContext]        = useState([]);
  const [notePickerOpen, setNotePickerOpen] = useState(false);
  const endRef        = useRef(null);
  const notePickerRef = useRef(null);

  useEffect(() => { endRef.current?.scrollIntoView({ behavior: 'smooth' }); }, [messages]);

  useEffect(() => {
    const hide = e => { if (notePickerRef.current && !notePickerRef.current.contains(e.target)) setNotePickerOpen(false); };
    document.addEventListener('mousedown', hide);
    return () => document.removeEventListener('mousedown', hide);
  }, []);

  const addVerseContext = () => {
    if (!curBook) return;
    const ref = curVerse ? `${curBook} ${curChapter}:${curVerse}` : `${curBook} ${curChapter}`;
    setContext(prev => prev.includes(ref) ? prev : [...prev, ref]);
  };

  const addNoteContext = (note) => {
    const stripped = (note.text || '').replace(/<[^>]+>/g, '').slice(0, 120);
    const ref = `"${note.title || 'Note'}" — ${stripped}${stripped.length >= 120 ? '…' : ''}`;
    setContext(prev => [...prev, ref]);
    setNotePickerOpen(false);
  };

  const handleSend = () => {
    if (!text.trim()) return;
    const fullContent = context.length
      ? `${text.trim()}\n\n[Context: ${context.join('; ')}]`
      : text.trim();
    onSend(fullContent);
    setText('');
    setContext([]);
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', overflow: 'hidden', position: 'relative' }}>
      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem', padding: '0.8rem 1rem', borderBottom: '1px solid rgba(255,255,255,0.09)', flexShrink: 0 }}>
        <Button type="text" icon={<ArrowLeftOutlined />} onClick={onBack} style={{ color: 'rgba(255,198,26,0.65)', padding: '0 4px' }} />
        <div style={{ width: 26, height: 26, borderRadius: '50%', background: 'rgba(255,198,26,0.12)', border: '1px solid rgba(255,255,255,0.15)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
          <RobotOutlined style={{ color: 'var(--gold)', fontSize: '0.78rem' }} />
        </div>
        <Text strong style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.88rem', color: 'var(--parchment)', flex: 1 }}>
          {agentLabel(agent)}
        </Text>
      </div>

      {/* Messages */}
      <div style={{ flex: 1, overflowY: 'auto', padding: '0.75rem 0.85rem', display: 'flex', flexDirection: 'column', gap: '0.45rem' }}>
        {messages.length === 0 && !agentThinking && (
          <div style={{ textAlign: 'center', padding: '2.5rem 1rem', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '0.7rem' }}>
            <div style={{ width: 42, height: 42, borderRadius: '50%', background: 'rgba(255,198,26,0.07)', border: '1px solid rgba(255,255,255,0.108)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
              <RobotOutlined style={{ color: 'rgba(255,198,26,0.4)', fontSize: '1.1rem' }} />
            </div>
            <Text style={{ fontSize: '0.72rem', color: 'rgba(242,242,242,0.22)', fontFamily: "'Inter', sans-serif", fontStyle: 'italic' }}>
              Your spiritual guide is ready. Ask anything.
            </Text>
          </div>
        )}
        {messages.map((m, i) => (
          m.mine ? (
            <div key={i} className="msg-bubble sent">
              <AgentMessage text={m.text} isMine onNavigate={onNavigateVerse} />
              {m.timestamp && (
                <div className="msg-bubble-meta">
                  {new Date(m.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                </div>
              )}
            </div>
          ) : (
            // The agent's reply floats directly on the chat background —
            // no bubble container — centered rather than left-aligned.
            <div key={i} className="agent-response">
              <AgentMessage text={m.text} isMine={false} onNavigate={onNavigateVerse} />
              {m.timestamp && (
                <div className="agent-response-meta">
                  {new Date(m.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                </div>
              )}
            </div>
          )
        ))}
        {agentThinking && (
          <div className="agent-response">
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: '0.4rem' }}>
              <Spin size="small" />
              <span style={{ fontSize: '0.72rem', color: 'rgba(242,242,242,0.38)', fontStyle: 'italic' }}>Thinking…</span>
            </span>
          </div>
        )}
        <div ref={endRef} />
      </div>

      {/* Note picker dropdown */}
      {notePickerOpen && (
        <div ref={notePickerRef} style={{
          position: 'absolute', bottom: 100, left: 8, right: 8,
          background: 'rgba(10,7,2,0.98)', border: 'none',
          borderRadius: 8, maxHeight: 190, overflowY: 'auto', zIndex: 20, padding: '0.35rem',
        }}>
          <Text style={{ display: 'block', fontSize: '0.52rem', letterSpacing: '0.18em', textTransform: 'uppercase', color: 'rgba(255,198,26,0.4)', padding: '0.3rem 0.5rem 0.4rem' }}>
            Select a note
          </Text>
          {!(allNotes || []).length
            ? <Text style={{ fontSize: '0.7rem', color: 'rgba(242,242,242,0.3)', display: 'block', padding: '0.4rem 0.6rem' }}>No notes saved yet.</Text>
            : (allNotes || []).slice(0, 12).map((note, i) => (
                <div
                  key={note.id || i}
                  onClick={() => addNoteContext(note)}
                  style={{ padding: '0.4rem 0.6rem', cursor: 'pointer', borderRadius: 5, fontSize: '0.72rem', fontFamily: "'Inter', sans-serif", color: 'rgba(242,242,242,0.7)', transition: 'background 0.12s' }}
                  onMouseEnter={e => e.currentTarget.style.background = 'rgba(255,198,26,0.09)'}
                  onMouseLeave={e => e.currentTarget.style.background = 'transparent'}
                >
                  {note.title || 'Untitled note'}
                </div>
              ))
          }
        </div>
      )}

      {/* Context bar */}
      <div style={{ padding: '0.28rem 0.75rem', borderTop: '1px solid rgba(255,255,255,0.06)', background: 'rgba(255,198,26,0.035)', display: 'flex', flexWrap: 'wrap', gap: '0.3rem', alignItems: 'center', flexShrink: 0, minHeight: 32 }}>
        <Button size="small" type="text" icon={<BookOutlined style={{ fontSize: '0.66rem' }} />} onClick={addVerseContext} disabled={!curBook}
          style={{ fontSize: '0.6rem', color: 'rgba(255,198,26,0.65)', padding: '0 5px', height: 22 }}>
          Verse
        </Button>
        <Button size="small" type="text" icon={<EditOutlined style={{ fontSize: '0.66rem' }} />} onClick={() => setNotePickerOpen(v => !v)}
          style={{ fontSize: '0.6rem', color: 'rgba(255,198,26,0.65)', padding: '0 5px', height: 22 }}>
          Notes
        </Button>
        {context.length > 0 && <Divider type="vertical" style={{ borderColor: 'rgba(255,255,255,0.09)', margin: '0 1px', height: 12 }} />}
        {context.map((c, i) => (
          <span key={i} style={{ display: 'inline-flex', alignItems: 'center', gap: '0.2rem', padding: '0.1rem 0.38rem', background: 'rgba(255,198,26,0.1)', border: '1px solid rgba(255,255,255,0.132)', borderRadius: 3, fontSize: '0.58rem', color: 'rgba(242,242,242,0.75)', fontFamily: "'Inter', sans-serif", maxWidth: 130 }}>
            <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}>{c}</span>
            <CloseOutlined style={{ fontSize: '0.5rem', cursor: 'pointer', color: 'rgba(255,198,26,0.6)', flexShrink: 0 }} onClick={() => setContext(prev => prev.filter(x => x !== c))} />
          </span>
        ))}
      </div>

      {/* Input */}
      <div style={{ display: 'flex', gap: '0.4rem', padding: '0.6rem 0.75rem', borderTop: '1px solid rgba(255,255,255,0.09)', flexShrink: 0, alignItems: 'flex-end' }}>
        <Input
          value={text}
          onChange={e => setText(e.target.value)}
          onPressEnter={e => { if (!e.shiftKey) { e.preventDefault(); handleSend(); } }}
          placeholder="Ask your spiritual guide…"
          style={{ flex: 1, borderRadius: 20, fontSize: '0.82rem' }}
        />
        <Button type="primary" shape="circle" icon={<SendOutlined />} onClick={handleSend} disabled={!text.trim() || agentThinking} style={{ flexShrink: 0 }} />
      </div>
    </div>
  );
}
