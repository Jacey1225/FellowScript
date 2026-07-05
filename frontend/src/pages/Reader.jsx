import React, { useEffect, useLayoutEffect, useState, useRef, useCallback } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Layout, Input, Button, Avatar, Typography, Divider, Modal, Form, Checkbox, Spin } from 'antd';
import { AgentMessage } from '../components/RichText.jsx';
import {
  SendOutlined, ArrowLeftOutlined, PlusOutlined,
  MessageOutlined, BookOutlined, TeamOutlined,
  EditOutlined, DeleteOutlined, UserAddOutlined,
  RobotOutlined, CloseOutlined,
} from '@ant-design/icons';

import AppNav           from '../components/AppNav.jsx';
import BibleNavigator  from '../components/BibleNavigator.jsx';
import BibleCard       from '../components/BibleCard.jsx';
import NotesSidebar    from '../components/NotesSidebar.jsx';
import HighlightPicker from '../components/HighlightPicker.jsx';
import SessionCreator  from '../components/SessionCreator.jsx';
import SessionWidget   from '../components/SessionWidget.jsx';
import BookmarkButton  from '../components/BookmarkButton.jsx';

import { useAuth }        from '../context/AuthContext.jsx';
import { useAgentChat }  from '../hooks/useAgentChat.js';
import { useBible }       from '../hooks/useBible.js';
import { useHighlights }  from '../hooks/useHighlights.js';
import { useNotes }       from '../hooks/useNotes.js';
import { useMessaging }   from '../hooks/useMessaging.js';
import { useSessions }    from '../hooks/useSessions.js';
import { useBookmarks }   from '../hooks/useBookmarks.js';

const { Text, Title } = Typography;
const MOBILE_BP = 900;
function isMobile() { return window.innerWidth <= MOBILE_BP; }

const FONT_SIZES = [
  { size: '1.04rem', lineHeight: '2.15' },
  { size: '1.2rem',  lineHeight: '2.05' },
  { size: '1.38rem', lineHeight: '1.9'  },
];
const FONT_SIZE_LABELS = ['Default', 'Large', 'Largest'];

// ── Helpers ───────────────────────────────────────────────────────────────────

function agentLabel(agent) {
  if (agent?.name) return agent.name;
  if (!agent?.role || agent.role.startsWith('You are a spiritual')) return 'Spiritual Guide';
  const firstLine = agent.role.split('\n').find(l => l.trim());
  return (firstLine || '').slice(0, 26) || 'Agent';
}

// ── Agent row ─────────────────────────────────────────────────────────────────

function AgentRow({ agent, active, onOpen }) {
  return (
    <div
      onClick={onOpen}
      style={{
        display: 'flex', alignItems: 'center', gap: '0.5rem',
        padding: '0.55rem 0.8rem', cursor: 'pointer',
        background: active ? 'rgba(200,134,26,0.12)' : 'transparent',
        borderLeft: `2px solid ${active ? 'var(--gold)' : 'transparent'}`,
        transition: 'background 0.15s, border-color 0.15s',
      }}
      onMouseEnter={e => { if (!active) e.currentTarget.style.background = 'rgba(200,134,26,0.06)'; }}
      onMouseLeave={e => { if (!active) e.currentTarget.style.background = 'transparent'; }}
    >
      <div style={{
        width: 30, height: 30, borderRadius: '50%', flexShrink: 0,
        background: 'rgba(200,134,26,0.12)', border: '1px solid rgba(200,134,26,0.28)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>
        <RobotOutlined style={{ color: 'var(--gold)', fontSize: '0.8rem' }} />
      </div>
      <Text style={{
        fontFamily: "'Lora', serif", fontSize: '0.72rem',
        color: active ? 'var(--parchment)' : 'rgba(244,228,193,0.65)',
        overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1,
      }}>
        {agentLabel(agent)}
      </Text>
    </div>
  );
}

// ── Agent chat panel ──────────────────────────────────────────────────────────

function AgentChatPanel({ agent, messages, user, onBack, onSend, agentThinking, curBook, curChapter, curVerse, allNotes, onNavigateVerse }) {
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
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem', padding: '0.8rem 1rem', borderBottom: '1px solid rgba(200,134,26,0.15)', flexShrink: 0 }}>
        <Button type="text" icon={<ArrowLeftOutlined />} onClick={onBack} style={{ color: 'rgba(200,134,26,0.65)', padding: '0 4px' }} />
        <div style={{ width: 26, height: 26, borderRadius: '50%', background: 'rgba(200,134,26,0.12)', border: '1px solid rgba(200,134,26,0.25)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
          <RobotOutlined style={{ color: 'var(--gold)', fontSize: '0.78rem' }} />
        </div>
        <Text strong style={{ fontFamily: "'Lora', serif", fontSize: '0.88rem', color: 'var(--parchment)', flex: 1 }}>
          {agentLabel(agent)}
        </Text>
      </div>

      {/* Messages */}
      <div style={{ flex: 1, overflowY: 'auto', padding: '0.75rem 0.85rem', display: 'flex', flexDirection: 'column', gap: '0.45rem' }}>
        {messages.length === 0 && !agentThinking && (
          <div style={{ textAlign: 'center', padding: '2.5rem 1rem', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '0.7rem' }}>
            <div style={{ width: 42, height: 42, borderRadius: '50%', background: 'rgba(200,134,26,0.07)', border: '1px solid rgba(200,134,26,0.18)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
              <RobotOutlined style={{ color: 'rgba(200,134,26,0.4)', fontSize: '1.1rem' }} />
            </div>
            <Text style={{ fontSize: '0.72rem', color: 'rgba(244,228,193,0.22)', fontFamily: "'Lora', serif", fontStyle: 'italic' }}>
              Your spiritual guide is ready. Ask anything.
            </Text>
          </div>
        )}
        {messages.map((m, i) => (
          <div key={i} className={`msg-bubble ${m.mine ? 'sent' : 'received'}`}>
            {!m.mine && <div className="msg-bubble-sender">{m.sender}</div>}
            <AgentMessage text={m.text} isMine={m.mine} onNavigate={onNavigateVerse} />
            {m.timestamp && (
              <div className="msg-bubble-meta">
                {new Date(m.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
              </div>
            )}
          </div>
        ))}
        {agentThinking && (
          <div className="msg-bubble received">
            <div className="msg-bubble-sender">Agent</div>
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: '0.4rem' }}>
              <Spin size="small" />
              <span style={{ fontSize: '0.72rem', color: 'rgba(244,228,193,0.38)', fontStyle: 'italic' }}>Thinking…</span>
            </span>
          </div>
        )}
        <div ref={endRef} />
      </div>

      {/* Note picker dropdown */}
      {notePickerOpen && (
        <div ref={notePickerRef} style={{
          position: 'absolute', bottom: 100, left: 8, right: 8,
          background: 'rgba(10,7,2,0.98)', border: '1px solid rgba(200,134,26,0.2)',
          borderRadius: 8, maxHeight: 190, overflowY: 'auto', zIndex: 20, padding: '0.35rem',
          boxShadow: '0 8px 32px rgba(0,0,0,0.6)',
        }}>
          <Text style={{ display: 'block', fontSize: '0.52rem', letterSpacing: '0.18em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.4)', padding: '0.3rem 0.5rem 0.4rem' }}>
            Select a note
          </Text>
          {!(allNotes || []).length
            ? <Text style={{ fontSize: '0.7rem', color: 'rgba(244,228,193,0.3)', display: 'block', padding: '0.4rem 0.6rem' }}>No notes saved yet.</Text>
            : (allNotes || []).slice(0, 12).map((note, i) => (
                <div
                  key={note.id || i}
                  onClick={() => addNoteContext(note)}
                  style={{ padding: '0.4rem 0.6rem', cursor: 'pointer', borderRadius: 5, fontSize: '0.72rem', fontFamily: "'Lora', serif", color: 'rgba(244,228,193,0.7)', transition: 'background 0.12s' }}
                  onMouseEnter={e => e.currentTarget.style.background = 'rgba(200,134,26,0.09)'}
                  onMouseLeave={e => e.currentTarget.style.background = 'transparent'}
                >
                  {note.title || 'Untitled note'}
                </div>
              ))
          }
        </div>
      )}

      {/* Context bar */}
      <div style={{ padding: '0.28rem 0.75rem', borderTop: '1px solid rgba(200,134,26,0.1)', background: 'rgba(200,134,26,0.035)', display: 'flex', flexWrap: 'wrap', gap: '0.3rem', alignItems: 'center', flexShrink: 0, minHeight: 32 }}>
        <Button size="small" type="text" icon={<BookOutlined style={{ fontSize: '0.66rem' }} />} onClick={addVerseContext} disabled={!curBook}
          style={{ fontSize: '0.6rem', color: 'rgba(200,134,26,0.65)', padding: '0 5px', height: 22 }}>
          Verse
        </Button>
        <Button size="small" type="text" icon={<EditOutlined style={{ fontSize: '0.66rem' }} />} onClick={() => setNotePickerOpen(v => !v)}
          style={{ fontSize: '0.6rem', color: 'rgba(200,134,26,0.65)', padding: '0 5px', height: 22 }}>
          Notes
        </Button>
        {context.length > 0 && <Divider type="vertical" style={{ borderColor: 'rgba(200,134,26,0.15)', margin: '0 1px', height: 12 }} />}
        {context.map((c, i) => (
          <span key={i} style={{ display: 'inline-flex', alignItems: 'center', gap: '0.2rem', padding: '0.1rem 0.38rem', background: 'rgba(200,134,26,0.1)', border: '1px solid rgba(200,134,26,0.22)', borderRadius: 3, fontSize: '0.58rem', color: 'rgba(244,228,193,0.75)', fontFamily: "'Lora', serif", maxWidth: 130 }}>
            <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}>{c}</span>
            <CloseOutlined style={{ fontSize: '0.5rem', cursor: 'pointer', color: 'rgba(200,134,26,0.6)', flexShrink: 0 }} onClick={() => setContext(prev => prev.filter(x => x !== c))} />
          </span>
        ))}
      </div>

      {/* Input */}
      <div style={{ display: 'flex', gap: '0.4rem', padding: '0.6rem 0.75rem', borderTop: '1px solid rgba(200,134,26,0.15)', flexShrink: 0, alignItems: 'flex-end' }}>
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

// ── Contacts island ───────────────────────────────────────────────────────────

function ContactRow({ contact, active, onOpen, onRemove, onEdit }) {
  return (
    <div
      onClick={() => onOpen(contact)}
      style={{
        display: 'flex', alignItems: 'center', gap: '0.5rem',
        padding: '0.55rem 0.8rem', cursor: 'pointer',
        background: active ? 'rgba(200,134,26,0.12)' : 'transparent',
        borderLeft: `2px solid ${active ? 'var(--gold)' : 'transparent'}`,
        transition: 'background 0.15s, border-color 0.15s',
      }}
      onMouseEnter={e => { if (!active) e.currentTarget.style.background = 'rgba(200,134,26,0.06)'; }}
      onMouseLeave={e => { if (!active) e.currentTarget.style.background = 'transparent'; }}
    >
      <Avatar
        size={30}
        style={{ background: 'rgba(200,134,26,0.15)', border: '1px solid rgba(200,134,26,0.3)', color: 'var(--gold)', fontSize: '0.72rem', flexShrink: 0, fontFamily: "'Playfair Display', serif" }}
      >
        {contact.name[0].toUpperCase()}
      </Avatar>
      <Text
        style={{ fontFamily: "'Lora', serif", fontSize: '0.72rem', color: active ? 'var(--parchment)' : 'rgba(244,228,193,0.65)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}
      >
        {contact.name}
      </Text>
    </div>
  );
}

function ContactsPanel({
  user, friends, groups, currentContact,
  onOpen, onAddFriend, onRemoveFriend, onCreateGroup, onUpdateGroup, onLeaveGroup,
  loaded, onLoad,
  agents, activeAgent, onOpenAgent, onNewAgent,
}) {
  const [friendInput,    setFriendInput]    = useState('');
  const [showAddFriend,  setShowAddFriend]  = useState(false);
  const [friendMsg,      setFriendMsg]      = useState(null); // { type: 'success'|'error', text }
  const [groupModal,     setGroupModal]     = useState(false);
  const [editingGroup,   setEditingGroup]   = useState(null);
  const [form]                              = Form.useForm();

  useEffect(() => { if (!loaded) onLoad(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const handleAddFriend = async () => {
    if (!friendInput.trim()) return;
    const result = await onAddFriend(friendInput.trim());
    if (result.ok) {
      setFriendInput('');
      setFriendMsg({ type: 'success', text: 'Friend request sent!' });
      await onLoad();
      setTimeout(() => { setShowAddFriend(false); setFriendMsg(null); }, 1800);
    } else {
      setFriendMsg({ type: 'error', text: result.detail || 'Request failed.' });
    }
  };

  const handleGroupOk = async () => {
    const vals = form.getFieldsValue();
    if (editingGroup) {
      await onUpdateGroup(editingGroup.id, vals.title, vals.members || []);
    } else {
      await onCreateGroup(vals.title, vals.members || []);
    }
    setGroupModal(false);
    setEditingGroup(null);
    form.resetFields();
    await onLoad();
  };

  const openNewGroup = () => { setEditingGroup(null); form.resetFields(); setGroupModal(true); };

  if (!user) {
    return (
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', height: '100%', padding: '1.2rem', textAlign: 'center', gap: '0.8rem' }}>
        <MessageOutlined style={{ fontSize: 22, color: 'rgba(200,134,26,0.35)' }} />
        <Text style={{ fontSize: '0.68rem', color: 'rgba(244,228,193,0.3)', lineHeight: 1.5 }}>Sign in to message study partners.</Text>
      </div>
    );
  }

  const groupList = Object.entries(groups || {});

  return (
    <>
      <div style={{ padding: '0.9rem 0.8rem 0.6rem', borderBottom: '1px solid rgba(200,134,26,0.12)', flexShrink: 0 }}>
        <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.58rem', letterSpacing: '0.24em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.55)' }}>
          Messages
        </Text>
      </div>

      <div style={{ flex: 1, overflowY: 'auto' }}>
        {/* Friends */}
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0.55rem 0.8rem 0.25rem' }}>
          <Text style={{ fontSize: '0.52rem', letterSpacing: '0.2em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.4)' }}>Friends</Text>
          <Button type="text" size="small" icon={<UserAddOutlined />} onClick={() => setShowAddFriend(v => !v)}
            style={{ color: 'rgba(200,134,26,0.5)', padding: '0 3px', height: 20 }} />
        </div>
        {showAddFriend && (
          <div style={{ padding: '0.25rem 0.7rem 0.4rem' }}>
            <Input
              size="small" placeholder="Username"
              value={friendInput}
              onChange={e => { setFriendInput(e.target.value); if (friendMsg) setFriendMsg(null); }}
              onPressEnter={handleAddFriend}
              suffix={<Button type="link" size="small" onClick={handleAddFriend} style={{ padding: 0, fontSize: '0.6rem' }}>Add</Button>}
              style={{ fontSize: '0.72rem' }}
            />
            {friendMsg && (
              <div style={{
                marginTop: '0.3rem',
                fontSize: '0.63rem',
                fontFamily: "'Lora', serif",
                color: friendMsg.type === 'success' ? '#6dbf7e' : '#e07070',
                display: 'flex',
                alignItems: 'center',
                gap: '0.3rem',
              }}>
                <span>{friendMsg.type === 'success' ? '✓' : '✕'}</span>
                {friendMsg.text}
              </div>
            )}
          </div>
        )}
        {!loaded
          ? <div style={{ textAlign: 'center', padding: '0.8rem' }}><Spin size="small" /></div>
          : friends.length === 0
            ? <Text style={{ display: 'block', textAlign: 'center', padding: '0.6rem 0.5rem', color: 'rgba(244,228,193,0.2)', fontSize: '0.62rem' }}>No friends yet</Text>
            : friends.map(f => (
                <ContactRow key={f.id} contact={f} active={currentContact?.id === f.id} onOpen={onOpen}
                  onRemove={() => { onRemoveFriend(f.id); onLoad(); }} />
              ))
        }

        {/* Groups */}
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0.55rem 0.8rem 0.25rem', borderTop: '1px solid rgba(200,134,26,0.08)', marginTop: '0.3rem' }}>
          <Text style={{ fontSize: '0.52rem', letterSpacing: '0.2em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.4)' }}>Groups</Text>
          <Button type="text" size="small" icon={<PlusOutlined />} onClick={openNewGroup}
            style={{ color: 'rgba(200,134,26,0.5)', padding: '0 3px', height: 20 }} />
        </div>
        {groupList.length === 0
          ? <Text style={{ display: 'block', textAlign: 'center', padding: '0.6rem 0.5rem', color: 'rgba(244,228,193,0.2)', fontSize: '0.62rem' }}>No groups yet</Text>
          : groupList.map(([gid, g]) => {
              const contact = { id: gid, name: g.title || gid.slice(0, 8), type: 'group', toUsers: g.users || [], group_id: gid };
              return (
                <ContactRow key={gid} contact={contact} active={currentContact?.id === gid} onOpen={onOpen}
                  onRemove={() => { onLeaveGroup(gid); onLoad(); }}
                  onEdit={() => { setEditingGroup(contact); form.setFieldsValue({ title: g.title, members: (g.users || []).filter(id => id !== user?.user_id) }); setGroupModal(true); }}
                />
              );
            })
        }

        {/* Agents */}
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0.55rem 0.8rem 0.25rem', borderTop: '1px solid rgba(200,134,26,0.08)', marginTop: '0.3rem' }}>
          <Text style={{ fontSize: '0.52rem', letterSpacing: '0.2em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.4)' }}>Agents</Text>
          <Button type="text" size="small" icon={<PlusOutlined />} onClick={onNewAgent}
            style={{ color: 'rgba(200,134,26,0.5)', padding: '0 3px', height: 20 }} />
        </div>
        {(agents || []).length === 0
          ? <Text style={{ display: 'block', textAlign: 'center', padding: '0.6rem 0.5rem', color: 'rgba(244,228,193,0.2)', fontSize: '0.62rem' }}>No agent chats yet</Text>
          : (agents || []).filter(a => a.enabled !== false).map(agent => (
              <AgentRow key={agent.id} agent={agent} active={activeAgent?.id === agent.id} onOpen={() => onOpenAgent(agent)} />
            ))
        }
      </div>

      {/* Group modal */}
      <Modal
        open={groupModal}
        title={<Text style={{ fontFamily: "'Playfair Display', serif", color: 'var(--parchment)' }}>{editingGroup ? 'Edit Group' : 'New Group'}</Text>}
        onOk={handleGroupOk}
        onCancel={() => { setGroupModal(false); setEditingGroup(null); form.resetFields(); }}
        okText={editingGroup ? 'Update' : 'Create'}
      >
        <Form form={form} layout="vertical">
          <Form.Item name="title" label="Group name" rules={[{ required: true }]}>
            <Input placeholder="Study Group" />
          </Form.Item>
          <Form.Item name="members" label="Members">
            <Checkbox.Group style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              {friends.map(f => (
                <Checkbox key={f.id} value={f.id} style={{ color: 'rgba(244,228,193,0.6)' }}>{f.name}</Checkbox>
              ))}
            </Checkbox.Group>
          </Form.Item>
        </Form>
      </Modal>
    </>
  );
}

// ── Chat panel (iMessage style) ───────────────────────────────────────────────

function ChatPanel({
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
          style={{ fontFamily: "'Lora', serif", fontSize: '0.88rem', color: 'var(--parchment)', flex: 1, cursor: contact?.type === 'group' ? 'pointer' : 'default' }}
          onClick={() => contact?.type === 'group' && setShowMembers(v => !v)}
        >
          {contact?.name}
          {contact?.type === 'group' && <TeamOutlined style={{ marginLeft: 6, fontSize: '0.72rem', color: 'rgba(200,134,26,0.5)' }} />}
        </Text>
        <button
          onClick={onOpenSessionCreator}
          style={{
            background: 'rgba(200,134,26,0.08)',
            border: '1px solid rgba(200,134,26,0.28)',
            borderRadius: 6,
            color: 'rgba(200,134,26,0.75)',
            cursor: 'pointer',
            fontSize: '0.62rem',
            letterSpacing: '0.06em',
            fontFamily: "'Lora', serif",
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
            <Avatar size={22} style={{ background: 'rgba(200,134,26,0.12)', border: '1px solid rgba(200,134,26,0.25)', color: 'var(--gold)', fontSize: '0.55rem' }}>
              {(user?.username || 'Y')[0].toUpperCase()}
            </Avatar>
            <Text style={{ fontSize: '0.72rem', color: 'var(--gold)', fontFamily: "'Lora', serif" }}>{user?.username} (you)</Text>
          </div>
          {groupMembers.map((m, i) => {
            const uname = m.username || m.user_id?.slice(0, 8) || '?';
            return (
              <div key={i} style={{ display: 'flex', alignItems: 'center', gap: '0.45rem', marginBottom: '0.3rem' }}>
                <Avatar size={22} style={{ background: 'rgba(200,134,26,0.12)', border: '1px solid rgba(200,134,26,0.25)', color: 'var(--gold)', fontSize: '0.55rem' }}>
                  {uname[0].toUpperCase()}
                </Avatar>
                <Text style={{ fontSize: '0.72rem', color: 'rgba(244,228,193,0.65)', fontFamily: "'Lora', serif" }}>{uname}</Text>
              </div>
            );
          })}
        </div>
      )}

      {/* Messages */}
      <div style={{ flex: 1, overflowY: 'auto', padding: '0.75rem 0.85rem', display: 'flex', flexDirection: 'column', gap: '0.45rem' }}>
        {messages.length === 0 && (
          <div style={{ textAlign: 'center', padding: '2rem 1rem' }}>
            <Text style={{ fontSize: '0.72rem', color: 'rgba(244,228,193,0.22)', fontFamily: "'Lora', serif" }}>No messages yet. Say hello!</Text>
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

// ── Main Reader ───────────────────────────────────────────────────────────────

export default function Reader() {
  const { user } = useAuth();
  const [searchParams, setSearchParams] = useSearchParams();

  const {
    loading, loadError, curBook, curChapter,
    chapterHTML, verseNums, books,
    loadBible, setBook, setChapter, chapterCount, verseCount, getPreamble,
    setChapterRenderedCallback,
  } = useBible();

  const [curVerse,       setCurVerse]       = useState(null);
  const [pickerVisible,  setPickerVisible]  = useState(false);
  const [pickerPos,      setPickerPos]      = useState({ x: 0, y: 0 });
  const [selectedVerse,  setSelectedVerse]  = useState(null);
  const lastSpanRef = useRef(null);

  const {
    localHl, groupHighlights, groupUsernames,
    loadHighlights, applyHighlights,
    setHighlight, clearHighlight,
    loadGroupHighlights, clearGroupHighlights,
  } = useHighlights({ user, curBook, curChapter });

  const {
    allNotes, groupNotes, currentGroupId, groups, groupLoading,
    filteredNotes, filteredGroup, filterActive,
    loadNotes, loadGroups, selectGroup,
    saveNote, deleteNote, postReply, loadDetailReplies,
    applyFilter, clearFilter,
  } = useNotes({ user, curBook, curChapter, vsValue: curVerse });

  const {
    friends, groups: msgGroups, currentContact, messages, groupMembers,
    wsRef,
    connectWS, disconnectWS, setOnSessionSignal,
    loadContacts, openChat, closeChat, sendMessage,
    addFriend, removeFriend, createGroup, updateGroup, leaveGroup,
  } = useMessaging({ user });

  const {
    sessions, activeSessionId, talkingUserId,
    showCreator, editingSession,
    openCreator, closeCreator,
    loadSessions, createSession, updateSession, deleteSession,
    joinSession, leaveSession,
    handleSignal,
    videoEnabled, videoTiles, toggleVideo, bindVideoTile,
  } = useSessions({ user, wsRef, currentContact });

  const {
    agents, agentMessages, activeAgent, agentThinking,
    loadAgents, openAgentChat, closeAgentChat, sendAgentMessage,
    createAgent, summarizeSession,
  } = useAgentChat({ user, onNoteSaved: loadNotes });

  const { bookmarks, loadBookmarks, addBookmark, removeBookmark } = useBookmarks({ user });

  const [contactsLoaded, setContactsLoaded] = useState(false);

  // Mobile overlay state
  const [mobileSidebar, setMobileSidebar] = useState(null); // 'notes' | 'messages' | null
  const isMob = isMobile();

  // Bible font size
  const [fontSizeIdx, setFontSizeIdx] = useState(() => {
    try { return Math.min(parseInt(localStorage.getItem('fs_font_size') || '0', 10), FONT_SIZES.length - 1); }
    catch { return 0; }
  });

  useEffect(() => {
    const { size, lineHeight } = FONT_SIZES[fontSizeIdx];
    document.documentElement.style.setProperty('--bible-font-size', size);
    document.documentElement.style.setProperty('--bible-line-height', lineHeight);
    try { localStorage.setItem('fs_font_size', fontSizeIdx); } catch {}
  }, [fontSizeIdx]);

  const cycleFontSize = useCallback(() => setFontSizeIdx(i => (i + 1) % FONT_SIZES.length), []);

  // ── Init ────────────────────────────────────────────────────────────────────
  useEffect(() => {
    loadBible().then(data => {
      if (!data) return;
      const book  = searchParams.get('book');
      const chNum = parseInt(searchParams.get('ch') || '') || null;
      const vsNum = parseInt(searchParams.get('vs') || '') || null;
      if (book && data[book]) {
        // Deep-link from URL params (e.g. verse navigation from sessions)
        setBook(book);
        setChapter(chNum || 1, book, data);
        if (vsNum) setCurVerse(vsNum);
      } else {
        // Restore last visited position, fall back to Genesis 1
        try {
          const saved = JSON.parse(localStorage.getItem('fs_bible_pos') || 'null');
          if (saved?.book && data[saved.book]) {
            setBook(saved.book);
            setChapter(saved.chapter || 1, saved.book, data);
            return;
          }
        } catch {}
        const firstBook = Object.keys(data)[0];
        setBook(firstBook);
        setChapter(1, firstBook, data);
      }
    });
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (user) { loadHighlights(); loadNotes(); loadGroups(); loadBookmarks(); connectWS(); loadAgents(); }
    return () => disconnectWS();
  }, [user]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => { setOnSessionSignal(handleSignal); }, [setOnSessionSignal, handleSignal]);

  // Restore last selected notes group once the groups list is loaded
  const groupRestoredRef = useRef(false);
  useEffect(() => {
    if (!user || groups.length === 0 || groupRestoredRef.current) return;
    groupRestoredRef.current = true;
    try {
      const saved = localStorage.getItem('fs_notes_group');
      if (saved && groups.find(g => g.id === saved)) {
        handleGroupChange(saved);
      } else if (saved) {
        try { localStorage.removeItem('fs_notes_group'); } catch {}
      }
    } catch {}
  }, [user, groups]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (!curBook) return;
    const params = { book: curBook };
    if (curChapter) params.ch = curChapter;
    if (curVerse)   params.vs = curVerse;
    setSearchParams(params, { replace: true });
  }, [curBook, curChapter, curVerse]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => { setChapterRenderedCallback(() => loadHighlights()); }, [setChapterRenderedCallback, loadHighlights]);

  // Disable browser scroll restoration so it can't fight our programmatic scrolls
  useEffect(() => {
    if ('scrollRestoration' in history) history.scrollRestoration = 'manual';
  }, []);

  // Scroll to top synchronously before paint whenever a new chapter loads without a target verse.
  // #root is the real scroll container (height:100% + overflow-x:hidden forces overflow-y:auto).
  useLayoutEffect(() => {
    if (!chapterHTML || curVerse) return;
    const root = document.getElementById('root');
    if (root) root.scrollTop = 0;
  }, [chapterHTML]); // eslint-disable-line react-hooks/exhaustive-deps

  // Scroll to a specific verse after paint (needs the element in the DOM first)
  useEffect(() => {
    if (!chapterHTML || !curVerse) return;
    const el = document.getElementById(`vs${curVerse}`);
    if (!el) return;
    const root = document.getElementById('root');
    const offset = el.getBoundingClientRect().top + (root ? root.scrollTop : window.scrollY) - 120;
    if (root) root.scrollTop = offset;
    else window.scrollTo({ top: offset, behavior: 'smooth' });
  }, [chapterHTML]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    const hide = () => { setPickerVisible(false); lastSpanRef.current?.classList.remove('active'); lastSpanRef.current = null; };
    document.addEventListener('click', hide);
    return () => document.removeEventListener('click', hide);
  }, []);

  // ── Handlers ────────────────────────────────────────────────────────────────
  const handleNavigate = useCallback((book, ch) => {
    setBook(book);
    setChapter(ch, book, null);
    setCurVerse(null);
    setPickerVisible(false);
  }, [setBook, setChapter]);

  const handleNavigateVerse = useCallback((book, ch, vs) => {
    setBook(book);
    setChapter(ch, book, null);
    setCurVerse(vs);
    setPickerVisible(false);
  }, [setBook, setChapter]);

  const getChapterCount = useCallback((book) => chapterCount(book, null), [chapterCount]);

  const handleVerseChange   = useCallback((vs) => {
    setCurVerse(vs);
    document.getElementById(`vs${vs}`)?.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }, []);
  const handlePrev = useCallback(() => { if (curChapter > 1) { setChapter(curChapter - 1, null, null); setCurVerse(null); } }, [curChapter, setChapter]);
  const handleNext = useCallback(() => { const mx = chapterCount(curBook, null); if (curChapter < mx) { setChapter(curChapter + 1, null, null); setCurVerse(null); } }, [curBook, curChapter, chapterCount, setChapter]);

  const handleVerseClick = useCallback((span, vNum, e) => {
    e.stopPropagation();
    if (lastSpanRef.current && lastSpanRef.current !== span) lastSpanRef.current.classList.remove('active');
    span.classList.add('active');
    lastSpanRef.current = span;
    setCurVerse(vNum);
    setSelectedVerse(vNum);
    const rect = span.getBoundingClientRect();
    setPickerPos({ x: Math.max(8, Math.min(rect.left, window.innerWidth - 220)), y: rect.top > 80 ? rect.top - 52 : rect.bottom + 8 });
    setPickerVisible(true);
  }, []);

  const handleHighlightColor = useCallback(async (color) => {
    if (!selectedVerse) return;
    await setHighlight(selectedVerse, color);
    setPickerVisible(false);
    lastSpanRef.current?.classList.remove('active'); lastSpanRef.current = null;
  }, [selectedVerse, setHighlight]);

  const handleClearHighlight = useCallback(async () => {
    if (!selectedVerse) return;
    await clearHighlight(selectedVerse);
    setPickerVisible(false);
    lastSpanRef.current?.classList.remove('active'); lastSpanRef.current = null;
  }, [selectedVerse, clearHighlight]);

  const handleGroupChange = useCallback(async (groupId) => {
    await selectGroup(groupId, async (gid) => { if (gid) await loadGroupHighlights(gid); else clearGroupHighlights(); });
  }, [selectGroup, loadGroupHighlights, clearGroupHighlights]);

  const handleLoadContacts = useCallback(async () => { await loadContacts(); setContactsLoaded(true); }, [loadContacts]);

  const handleOpenChat = useCallback(async (contact) => {
    closeAgentChat();
    await openChat(contact);
    loadSessions(contact);
    if (isMobile()) setMobileSidebar('messages');
  }, [openChat, loadSessions, closeAgentChat]);

  const handleCloseChat = useCallback(() => { closeChat(); }, [closeChat]);

  const handleOpenAgent = useCallback(async (agent) => {
    closeChat();
    await openAgentChat(agent);
    if (isMobile()) setMobileSidebar('messages');
  }, [openAgentChat, closeChat]);

  const handleCloseAgent = useCallback(() => { closeAgentChat(); }, [closeAgentChat]);

  const handleNewAgent = useCallback(async () => {
    const agent = await createAgent();
    if (agent) await handleOpenAgent(agent);
  }, [createAgent, handleOpenAgent]);

  const handleLeaveSession = useCallback(async () => {
    const session = sessions.find(s => s.id === activeSessionId);
    await leaveSession();
    if (session?.summarize) {
      const enabledAgent = agents.find(a => a.enabled !== false);
      if (enabledAgent) {
        const groupId = currentContact?.group_id || currentContact?.id || '';
        await summarizeSession(enabledAgent.id, session, groupId);
        loadNotes();
      }
    }
  }, [sessions, activeSessionId, leaveSession, agents, currentContact, summarizeSession, loadNotes]);

  // ── Derived ─────────────────────────────────────────────────────────────────
  const preamble = getPreamble(curBook, null);
  const chCount  = chapterCount(curBook, null);
  const notesData = { all: allNotes, filtered: filteredNotes, group: groupNotes, filteredGroup };

  // Shared notes sidebar props
  const notesSidebarProps = {
    user, notes: notesData, curBook, curChapter, curVerse,
    groups, currentGroupId, onGroupChange: handleGroupChange,
    onSaveNote: saveNote, onDeleteNote: deleteNote,
    onReply: postReply, onLoadReplies: loadDetailReplies,
    applyFilter, clearFilter, filterActive,
    allNotes, groupNotes, groupLoading,
    books, chapterCount: getChapterCount, verseCount,
    localHl, groupHighlights, groupUsernames,
    onNavigateVerse: handleNavigateVerse,
  };

  // Shared contacts props
  const contactsProps = {
    user, friends, groups: msgGroups, currentContact,
    onOpen: handleOpenChat,
    onAddFriend: addFriend, onRemoveFriend: removeFriend,
    onCreateGroup: createGroup, onUpdateGroup: updateGroup, onLeaveGroup: leaveGroup,
    loaded: contactsLoaded, onLoad: handleLoadContacts,
    agents, activeAgent, onOpenAgent: handleOpenAgent, onNewAgent: handleNewAgent,
  };

  return (
    <Layout style={{ minHeight: '100vh', background: 'transparent', overflow: 'hidden' }}>
      <AppNav />

      <div className="scripture-nav-bar">
        <BibleNavigator
          books={books} curBook={curBook} curChapter={curChapter}
          onNavigate={handleNavigate} chapterCount={getChapterCount}
        />
        <button
          className={`nav-pill-btn${fontSizeIdx > 0 ? ' open' : ''}`}
          onClick={cycleFontSize}
          title={`Text size: ${FONT_SIZE_LABELS[fontSizeIdx]} — click to cycle`}
          style={{ marginLeft: '0.5rem', gap: '0.25rem', letterSpacing: 0 }}
        >
          <span style={{ fontSize: '0.72rem', opacity: 0.7, lineHeight: 1 }}>A</span>
          <span style={{ fontSize: '1rem', lineHeight: 1 }}>A</span>
          {fontSizeIdx > 0 && (
            <span style={{ fontSize: '0.42rem', color: 'var(--gold)', letterSpacing: '0.05em', marginLeft: '0.1rem' }}>
              {'●'.repeat(fontSizeIdx)}
            </span>
          )}
        </button>
        <BookmarkButton
          user={user}
          bookmarks={bookmarks}
          curBook={curBook}
          curChapter={curChapter}
          onAdd={addBookmark}
          onRemove={removeBookmark}
          onNavigate={handleNavigate}
        />
      </div>

      {/* ── Bible reading area ── */}
      <main className="reader-main">
        <BibleCard
          loading={loading} loadError={loadError}
          curBook={curBook} curChapter={curChapter}
          chapterHTML={chapterHTML} chapterCount={chCount}
          preamble={preamble}
          onPrev={handlePrev} onNext={handleNext}
          onVerseClick={handleVerseClick}
          applyHighlights={applyHighlights}
        />
      </main>

      <HighlightPicker
        visible={pickerVisible} position={pickerPos}
        onColor={handleHighlightColor} onClear={handleClearHighlight}
      />

      {/* ── Desktop right panel (50% of screen) ── */}
      <div className="reader-right-panel">
        {/* Single island: notes section left, contacts column right */}
        <div className="notes-island">

          {/* Notes column */}
          <div className="notes-section">
            <NotesSidebar {...notesSidebarProps} />
            {/* Chat overlays — regular contact or agent */}
            {(currentContact || activeAgent) && (
              <div className="chat-overlay">
                {activeAgent
                  ? <AgentChatPanel
                      agent={activeAgent}
                      messages={agentMessages}
                      user={user}
                      onBack={handleCloseAgent}
                      onSend={sendAgentMessage}
                      agentThinking={agentThinking}
                      curBook={curBook}
                      curChapter={curChapter}
                      curVerse={curVerse}
                      allNotes={allNotes}
                      onNavigateVerse={handleNavigateVerse}
                    />
                  : <ChatPanel
                      contact={currentContact}
                      messages={messages}
                      groupMembers={groupMembers}
                      user={user}
                      onBack={handleCloseChat}
                      onSend={sendMessage}
                      sessions={sessions}
                      activeSessionId={activeSessionId}
                      talkingUserId={talkingUserId}
                      onJoinSession={joinSession}
                      onLeaveSession={handleLeaveSession}
                      onOpenSessionCreator={() => openCreator()}
                      onEditSession={openCreator}
                      onDeleteSession={deleteSession}
                      onNavigateVerse={handleNavigateVerse}
                      videoEnabled={videoEnabled}
                      videoTiles={videoTiles}
                      onToggleVideo={toggleVideo}
                      bindVideoTile={bindVideoTile}
                    />
                }
              </div>
            )}
          </div>

          {/* Contacts column — right side of the same island */}
          <div className="contacts-section">
            <ContactsPanel {...contactsProps} />
          </div>

        </div>
      </div>

      {/* ── Mobile: bottom tab bar ── */}
      <div className="mobile-tab-bar">
        <button
          className={`mobile-tab${mobileSidebar === 'notes' ? ' active' : ''}`}
          onClick={() => setMobileSidebar(v => v === 'notes' ? null : 'notes')}
        >
          <BookOutlined style={{ fontSize: 18 }} />
          Notes
        </button>
        <button
          className={`mobile-tab${mobileSidebar === 'messages' ? ' active' : ''}`}
          onClick={() => setMobileSidebar(v => v === 'messages' ? null : 'messages')}
        >
          <MessageOutlined style={{ fontSize: 18 }} />
          Messages
        </button>
      </div>

      {/* ── Mobile overlays ── */}
      <div className={`mobile-overlay${mobileSidebar === 'notes' ? ' open' : ''}`}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem', padding: '0.9rem 1rem', borderBottom: '1px solid rgba(200,134,26,0.15)', background: 'rgba(6,4,1,0.98)', flexShrink: 0 }}>
          <button onClick={() => setMobileSidebar(null)} style={{ background: 'none', border: 'none', color: 'rgba(200,134,26,0.65)', cursor: 'pointer', fontSize: '1.1rem' }}>✕</button>
          <Text style={{ fontFamily: "'Playfair Display', serif", fontSize: '1rem', color: 'var(--parchment)' }}>Notes</Text>
        </div>
        <div style={{ flex: 1, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
          <NotesSidebar {...notesSidebarProps} />
        </div>
      </div>

      <div className={`mobile-overlay${mobileSidebar === 'messages' ? ' open' : ''}`}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem', padding: '0.9rem 1rem', borderBottom: '1px solid rgba(200,134,26,0.15)', background: 'rgba(6,4,1,0.98)', flexShrink: 0 }}>
          <button onClick={() => setMobileSidebar(null)} style={{ background: 'none', border: 'none', color: 'rgba(200,134,26,0.65)', cursor: 'pointer', fontSize: '1.1rem' }}>✕</button>
          <Text style={{ fontFamily: "'Playfair Display', serif", fontSize: '1rem', color: 'var(--parchment)' }}>Messages</Text>
        </div>
        <div style={{ flex: 1, minHeight: 0, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
          {activeAgent
            ? <AgentChatPanel
                agent={activeAgent}
                messages={agentMessages}
                user={user}
                onBack={handleCloseAgent}
                onSend={sendAgentMessage}
                agentThinking={agentThinking}
                curBook={curBook}
                curChapter={curChapter}
                curVerse={curVerse}
                allNotes={allNotes}
                onNavigateVerse={handleNavigateVerse}
              />
            : currentContact
              ? <ChatPanel
                  contact={currentContact}
                  messages={messages}
                  groupMembers={groupMembers}
                  user={user}
                  onBack={handleCloseChat}
                  onSend={sendMessage}
                  sessions={sessions}
                  activeSessionId={activeSessionId}
                  talkingUserId={talkingUserId}
                  onJoinSession={joinSession}
                  onLeaveSession={handleLeaveSession}
                  onOpenSessionCreator={() => openCreator()}
                  onEditSession={openCreator}
                  onDeleteSession={deleteSession}
                  onNavigateVerse={handleNavigateVerse}
                  videoEnabled={videoEnabled}
                  videoTiles={videoTiles}
                  onToggleVideo={toggleVideo}
                  bindVideoTile={bindVideoTile}
                />
              : <ContactsPanel {...contactsProps} />
          }
        </div>
      </div>

      <SessionCreator
        open={showCreator}
        editSession={editingSession}
        onClose={closeCreator}
        onCreate={createSession}
        onUpdate={updateSession}
        books={books}
        chapterCount={getChapterCount}
        verseCount={verseCount}
      />

    </Layout>
  );
}
