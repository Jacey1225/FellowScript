import React, { useEffect, useState, useRef, useCallback } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Layout, Input, Button, Avatar, Typography, Divider, Modal, Form, Checkbox, Spin } from 'antd';
import {
  SendOutlined, ArrowLeftOutlined, PlusOutlined,
  MessageOutlined, BookOutlined, TeamOutlined,
  EditOutlined, DeleteOutlined, UserAddOutlined, PhoneOutlined,
} from '@ant-design/icons';

import AppNav           from '../components/AppNav.jsx';
import BibleNavigator  from '../components/BibleNavigator.jsx';
import BibleCard       from '../components/BibleCard.jsx';
import NotesSidebar    from '../components/NotesSidebar.jsx';
import HighlightPicker from '../components/HighlightPicker.jsx';
import SessionCreator  from '../components/SessionCreator.jsx';
import SessionWidget   from '../components/SessionWidget.jsx';

import { useAuth }       from '../context/AuthContext.jsx';
import { useBible }      from '../hooks/useBible.js';
import { useHighlights } from '../hooks/useHighlights.js';
import { useNotes }      from '../hooks/useNotes.js';
import { useMessaging }  from '../hooks/useMessaging.js';
import { useSessions }   from '../hooks/useSessions.js';

const { Text, Title } = Typography;
const MOBILE_BP = 768;
function isMobile() { return window.innerWidth <= MOBILE_BP; }

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
}) {
  const [friendInput,    setFriendInput]    = useState('');
  const [showAddFriend,  setShowAddFriend]  = useState(false);
  const [groupModal,     setGroupModal]     = useState(false);
  const [editingGroup,   setEditingGroup]   = useState(null);
  const [form]                              = Form.useForm();

  useEffect(() => { if (!loaded) onLoad(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const handleAddFriend = async () => {
    if (!friendInput.trim()) return;
    const ok = await onAddFriend(friendInput.trim());
    if (ok) { setFriendInput(''); setShowAddFriend(false); await onLoad(); }
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
              value={friendInput} onChange={e => setFriendInput(e.target.value)}
              onPressEnter={handleAddFriend}
              suffix={<Button type="link" size="small" onClick={handleAddFriend} style={{ padding: 0, fontSize: '0.6rem' }}>Add</Button>}
              style={{ fontSize: '0.72rem' }}
            />
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
        <Button
          type="text"
          icon={<PhoneOutlined />}
          onClick={onOpenSessionCreator}
          title="Schedule a session"
          style={{ color: 'rgba(200,134,26,0.55)', padding: '0 4px' }}
        />
        <Text
          strong
          style={{ fontFamily: "'Lora', serif", fontSize: '0.88rem', color: 'var(--parchment)', flex: 1, cursor: contact?.type === 'group' ? 'pointer' : 'default' }}
          onClick={() => contact?.type === 'group' && setShowMembers(v => !v)}
        >
          {contact?.name}
          {contact?.type === 'group' && <TeamOutlined style={{ marginLeft: 6, fontSize: '0.72rem', color: 'rgba(200,134,26,0.5)' }} />}
        </Text>
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
    loadHighlights, applyHighlights,
    setHighlight, clearHighlight,
    loadGroupHighlights, clearGroupHighlights,
  } = useHighlights({ user, curBook, curChapter });

  const {
    allNotes, groupNotes, currentGroupId, groups,
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
  } = useSessions({ user, wsRef, currentContact });

  const [contactsLoaded, setContactsLoaded] = useState(false);

  // Mobile overlay state
  const [mobileSidebar, setMobileSidebar] = useState(null); // 'notes' | 'messages' | null
  const isMob = isMobile();

  // ── Init ────────────────────────────────────────────────────────────────────
  useEffect(() => {
    loadBible().then(data => {
      if (!data) return;
      const book  = searchParams.get('book');
      const chNum = parseInt(searchParams.get('ch') || '') || null;
      const vsNum = parseInt(searchParams.get('vs') || '') || null;
      if (book && data[book]) {
        setBook(book);
        if (chNum) setChapter(chNum, book, data);
        if (vsNum) setCurVerse(vsNum);
      }
    });
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (user) { loadHighlights(); loadNotes(); loadGroups(); connectWS(); }
    return () => disconnectWS();
  }, [user]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => { setOnSessionSignal(handleSignal); }, [setOnSessionSignal, handleSignal]);

  useEffect(() => {
    if (!curBook) return;
    const params = { book: curBook };
    if (curChapter) params.ch = curChapter;
    if (curVerse)   params.vs = curVerse;
    setSearchParams(params, { replace: true });
  }, [curBook, curChapter, curVerse]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => { setChapterRenderedCallback(() => loadHighlights()); }, [setChapterRenderedCallback, loadHighlights]);

  useEffect(() => {
    if (!chapterHTML || !curVerse) return;
    document.getElementById(`vs${curVerse}`)?.scrollIntoView({ behavior: 'smooth', block: 'center' });
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
    await openChat(contact);
    if (isMobile()) setMobileSidebar('messages');
  }, [openChat]);

  const handleCloseChat = useCallback(() => { closeChat(); }, [closeChat]);

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
    allNotes, groupNotes,
    books, chapterCount: getChapterCount, verseCount,
  };

  // Shared contacts props
  const contactsProps = {
    user, friends, groups: msgGroups, currentContact,
    onOpen: handleOpenChat,
    onAddFriend: addFriend, onRemoveFriend: removeFriend,
    onCreateGroup: createGroup, onUpdateGroup: updateGroup, onLeaveGroup: leaveGroup,
    loaded: contactsLoaded, onLoad: handleLoadContacts,
  };

  return (
    <Layout style={{ minHeight: '100vh', background: 'transparent', overflow: 'hidden' }}>
      <AppNav />

      <div className="scripture-nav-bar">
        <BibleNavigator
          books={books} curBook={curBook} curChapter={curChapter}
          onNavigate={handleNavigate} chapterCount={getChapterCount}
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
            {/* Chat only rendered when a contact is selected — slides in via CSS animation */}
            {currentContact && (
              <div className="chat-overlay">
                <ChatPanel
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
                  onLeaveSession={leaveSession}
                  onOpenSessionCreator={() => openCreator()}
                  onEditSession={openCreator}
                  onDeleteSession={deleteSession}
                  onNavigateVerse={handleNavigateVerse}
                />
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
          {currentContact
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
                onLeaveSession={leaveSession}
                onOpenSessionCreator={() => openCreator()}
                onEditSession={openCreator}
                onDeleteSession={deleteSession}
                onNavigateVerse={handleNavigateVerse}
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
