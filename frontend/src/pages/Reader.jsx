import React, { useEffect, useState, useRef, useCallback } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Layout, Button } from 'antd';
import { MessageOutlined, BookOutlined } from '@ant-design/icons';

import AppNav          from '../components/AppNav.jsx';
import ScriptureNav    from '../components/ScriptureNav.jsx';
import BibleCard       from '../components/BibleCard.jsx';
import NotesSidebar    from '../components/NotesSidebar.jsx';
import MessagingSidebar from '../components/MessagingSidebar.jsx';
import HighlightPicker from '../components/HighlightPicker.jsx';

import { useAuth }       from '../context/AuthContext.jsx';
import { useBible }      from '../hooks/useBible.js';
import { useHighlights } from '../hooks/useHighlights.js';
import { useNotes }      from '../hooks/useNotes.js';
import { useMessaging }  from '../hooks/useMessaging.js';

const MOBILE_BP = 640;

function isMobile() { return window.innerWidth <= MOBILE_BP; }

export default function Reader() {
  const { user } = useAuth();
  const [searchParams, setSearchParams] = useSearchParams();

  // ── Bible hook ────────────────────────────────────────────────────────────
  const {
    bible, loading, loadError, curBook, curChapter,
    chapterHTML, verseNums, books,
    loadBible, setBook, setChapter, chapterCount, getPreamble,
    setChapterRenderedCallback,
  } = useBible();

  // ── State for verse tracking ──────────────────────────────────────────────
  const [curVerse, setCurVerse]           = useState(null);
  const [pickerVisible, setPickerVisible] = useState(false);
  const [pickerPos, setPickerPos]         = useState({ x: 0, y: 0 });
  const [selectedVerse, setSelectedVerse] = useState(null);
  const lastSpanRef = useRef(null);

  // ── Highlights hook ───────────────────────────────────────────────────────
  const {
    loadHighlights, applyHighlights,
    setHighlight, clearHighlight,
    loadGroupHighlights, clearGroupHighlights,
  } = useHighlights({ user, curBook, curChapter });

  // ── Notes hook ────────────────────────────────────────────────────────────
  const {
    allNotes, groupNotes, currentGroupId, groups,
    filteredNotes, filteredGroup, filterActive,
    loadNotes, loadGroups, selectGroup,
    saveNote, deleteNote, postReply, loadDetailReplies,
    applyFilter, clearFilter,
  } = useNotes({ user, curBook, curChapter, vsValue: curVerse });

  // ── Messaging hook ────────────────────────────────────────────────────────
  const {
    friends, groups: msgGroups, currentContact, messages, groupMembers,
    connectWS, disconnectWS, loadContacts, openChat, closeChat, sendMessage,
    addFriend, removeFriend, createGroup, updateGroup, leaveGroup,
  } = useMessaging({ user });

  const [contactsLoaded, setContactsLoaded] = useState(false);

  // ── Sidebar widths (desktop resize) ──────────────────────────────────────
  const [notesW, setNotesW]   = useState(360);
  const [msgW,   setMsgW]     = useState(280);
  const [msgOpen, setMsgOpen] = useState(false);

  // ── Mobile sidebar state ──────────────────────────────────────────────────
  const [mobileSidebar, setMobileSidebar] = useState(null); // 'notes' | 'messages' | null

  // ── Init ──────────────────────────────────────────────────────────────────
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
    if (user) {
      loadHighlights();
      loadNotes();
      loadGroups();
      connectWS();
    }
    return () => disconnectWS();
  }, [user]); // eslint-disable-line react-hooks/exhaustive-deps

  // ── Update URL when book/chapter changes ──────────────────────────────────
  useEffect(() => {
    if (!curBook) return;
    const params = { book: curBook };
    if (curChapter) params.ch = curChapter;
    if (curVerse)   params.vs = curVerse;
    setSearchParams(params, { replace: true });
  }, [curBook, curChapter, curVerse]); // eslint-disable-line react-hooks/exhaustive-deps

  // ── Apply highlights after chapter renders ────────────────────────────────
  useEffect(() => {
    setChapterRenderedCallback(() => loadHighlights());
  }, [setChapterRenderedCallback, loadHighlights]);

  // ── Scroll to verse after chapter renders ─────────────────────────────────
  useEffect(() => {
    if (!chapterHTML || !curVerse) return;
    const target = document.getElementById(`vs${curVerse}`);
    if (target) target.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }, [chapterHTML]); // eslint-disable-line react-hooks/exhaustive-deps

  // ── Close picker on outside click ────────────────────────────────────────
  useEffect(() => {
    const hide = () => {
      setPickerVisible(false);
      lastSpanRef.current?.classList.remove('active');
      lastSpanRef.current = null;
    };
    document.addEventListener('click', hide);
    return () => document.removeEventListener('click', hide);
  }, []);

  // ── Navigation handlers ───────────────────────────────────────────────────
  const handleBookChange = useCallback((book) => {
    setBook(book);
    setPickerVisible(false);
    setCurVerse(null);
  }, [setBook]);

  const handleChapterChange = useCallback((ch) => {
    setChapter(ch, null, null);
    setPickerVisible(false);
    setCurVerse(null);
  }, [setChapter]);

  const handleVerseChange = useCallback((vs) => {
    setCurVerse(vs);
    const target = document.getElementById(`vs${vs}`);
    if (target) target.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }, []);

  const handlePrev = useCallback(() => {
    if (curChapter > 1) { setChapter(curChapter - 1, null, null); setCurVerse(null); }
  }, [curChapter, setChapter]);

  const handleNext = useCallback(() => {
    const max = chapterCount(curBook, null);
    if (curChapter < max) { setChapter(curChapter + 1, null, null); setCurVerse(null); }
  }, [curBook, curChapter, chapterCount, setChapter]);

  // ── Verse click → highlight picker ───────────────────────────────────────
  const handleVerseClick = useCallback((span, vNum, e) => {
    e.stopPropagation();
    if (lastSpanRef.current && lastSpanRef.current !== span) {
      lastSpanRef.current.classList.remove('active');
    }
    span.classList.add('active');
    lastSpanRef.current = span;
    setCurVerse(vNum);
    setSelectedVerse(vNum);

    const rect  = span.getBoundingClientRect();
    const px    = Math.min(rect.left, window.innerWidth - 220);
    const py    = rect.top > 80 ? rect.top - 52 : rect.bottom + 8;
    setPickerPos({ x: Math.max(8, px), y: py });
    setPickerVisible(true);
  }, []);

  const handleHighlightColor = useCallback(async (color) => {
    if (!selectedVerse) return;
    await setHighlight(selectedVerse, color);
    setPickerVisible(false);
    lastSpanRef.current?.classList.remove('active');
    lastSpanRef.current = null;
  }, [selectedVerse, setHighlight]);

  const handleClearHighlight = useCallback(async () => {
    if (!selectedVerse) return;
    await clearHighlight(selectedVerse);
    setPickerVisible(false);
    lastSpanRef.current?.classList.remove('active');
    lastSpanRef.current = null;
  }, [selectedVerse, clearHighlight]);

  // ── Group change ──────────────────────────────────────────────────────────
  const handleGroupChange = useCallback(async (groupId) => {
    await selectGroup(groupId, async (gid) => {
      if (gid) await loadGroupHighlights(gid);
      else clearGroupHighlights();
    });
  }, [selectGroup, loadGroupHighlights, clearGroupHighlights]);

  // ── Contacts load ─────────────────────────────────────────────────────────
  const handleLoadContacts = useCallback(async () => {
    await loadContacts();
    setContactsLoaded(true);
  }, [loadContacts]);

  // ── Sidebar resize handles ────────────────────────────────────────────────
  const startNotesResize = useCallback((e) => {
    e.preventDefault();
    const startX = e.clientX;
    const startW = notesW;
    const onMove = (me) => {
      const delta = startX - me.clientX;
      setNotesW(Math.max(240, Math.min(620, startW + delta)));
    };
    const onUp = () => {
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
    };
    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
  }, [notesW]);

  const startMsgResize = useCallback((e) => {
    e.preventDefault();
    const startX = e.clientX;
    const startW = msgW;
    const onMove = (me) => {
      const delta = me.clientX - startX;
      setMsgW(Math.max(220, Math.min(520, startW + delta)));
    };
    const onUp = () => {
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
    };
    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
  }, [msgW]);

  // ── Mobile sidebar toggle ─────────────────────────────────────────────────
  const openMobileNotes    = () => setMobileSidebar('notes');
  const openMobileMessages = () => setMobileSidebar('messages');
  const closeMobileSidebar = () => setMobileSidebar(null);

  // ── Derived data ──────────────────────────────────────────────────────────
  const preamble    = getPreamble(curBook, null);
  const chCount     = chapterCount(curBook, null);

  const notesData = {
    all:           allNotes,
    filtered:      filteredNotes,
    group:         groupNotes,
    filteredGroup: filteredGroup,
  };

  const sidebarStyle = (w) => ({ '--sidebar-w': `${w}px` });
  const msgSidebarStyle = (w) => ({ '--msg-sidebar-w': `${w}px` });

  // ── Mobile extra styles ───────────────────────────────────────────────────
  const isMob = isMobile();
  const notesClass = `notes-sidebar${isMob && mobileSidebar === 'notes'    ? ' open' : ''}`;
  const msgClass   = `msg-sidebar${isMob   && mobileSidebar === 'messages' ? ' open' : ''}`;

  return (
    <Layout style={{ minHeight: '100vh', background: 'transparent', overflow: 'hidden' }}>
      <video id="bg-video" autoPlay muted loop playsInline>
        <source src="/data/bg.mp4" type="video/mp4" />
      </video>

      <AppNav />

      <ScriptureNav
        books={books}
        curBook={curBook}
        curChapter={curChapter}
        verseNums={verseNums}
        curVerse={curVerse}
        onBookChange={handleBookChange}
        onChapterChange={handleChapterChange}
        onVerseChange={handleVerseChange}
        chapterCount={chCount}
      />

      {/* Main reader area */}
      <main
        className={`reader-main${msgOpen && !isMob ? ' msg-open' : ''}`}
        style={{
          paddingRight: !isMob ? notesW : 0,
          paddingLeft:  (!isMob && msgOpen) ? msgW + 24 : 0,
        }}
      >
        <BibleCard
          loading={loading}
          loadError={loadError}
          curBook={curBook}
          curChapter={curChapter}
          chapterHTML={chapterHTML}
          chapterCount={chCount}
          preamble={preamble}
          onPrev={handlePrev}
          onNext={handleNext}
          onVerseClick={handleVerseClick}
          applyHighlights={applyHighlights}
        />
      </main>

      {/* Highlight picker */}
      <HighlightPicker
        visible={pickerVisible}
        position={pickerPos}
        onColor={handleHighlightColor}
        onClear={handleClearHighlight}
      />

      {/* Notes sidebar */}
      <div
        className={notesClass}
        style={!isMob ? { width: notesW } : undefined}
      >
        <div
          className="sidebar-resize-handle"
          onMouseDown={startNotesResize}
        />
        <NotesSidebar
          user={user}
          notes={notesData}
          curBook={curBook}
          curChapter={curChapter}
          curVerse={curVerse}
          groups={groups}
          currentGroupId={currentGroupId}
          onGroupChange={handleGroupChange}
          onSaveNote={saveNote}
          onDeleteNote={deleteNote}
          onReply={postReply}
          onLoadReplies={loadDetailReplies}
          applyFilter={applyFilter}
          clearFilter={clearFilter}
          filterActive={filterActive}
          allNotes={allNotes}
          groupNotes={groupNotes}
        />
      </div>

      {/* Messaging sidebar */}
      <div
        className={msgClass}
        style={!isMob ? { width: msgOpen ? msgW : 0, overflow: msgOpen ? 'hidden' : 'hidden', display: msgOpen ? 'flex' : 'none' } : undefined}
      >
        <div
          className="msg-resize-handle"
          onMouseDown={startMsgResize}
        />
        <MessagingSidebar
          user={user}
          friends={friends}
          groups={msgGroups}
          currentContact={currentContact}
          messages={messages}
          groupMembers={groupMembers}
          onLoadContacts={handleLoadContacts}
          onOpenChat={openChat}
          onCloseChat={closeChat}
          onSend={sendMessage}
          onAddFriend={addFriend}
          onRemoveFriend={removeFriend}
          onCreateGroup={createGroup}
          onUpdateGroup={updateGroup}
          onLeaveGroup={leaveGroup}
          loaded={contactsLoaded}
        />
      </div>

      {/* Desktop messages toggle button */}
      {!isMob && (
        <button
          onClick={() => setMsgOpen(v => !v)}
          style={{
            position: 'fixed',
            bottom: '2rem',
            left: msgOpen ? msgW + 12 : 12,
            zIndex: 85,
            background: msgOpen ? 'rgba(200,134,26,0.18)' : 'rgba(6,4,1,0.88)',
            border: '1px solid rgba(200,134,26,0.35)',
            borderRadius: 8,
            color: 'var(--gold)',
            fontFamily: "'Lora', serif",
            fontSize: '0.7rem',
            letterSpacing: '0.12em',
            textTransform: 'uppercase',
            padding: '0.5rem 0.85rem',
            cursor: 'pointer',
            transition: 'left 0.3s ease, background 0.2s',
          }}
        >
          {msgOpen ? '← Close' : 'Messages'}
        </button>
      )}

      {/* Mobile bottom tab bar */}
      {isMob && (
        <div style={{
          position: 'fixed',
          bottom: 0, left: 0, right: 0,
          zIndex: 120,
          display: 'flex',
          background: 'rgba(6,4,1,0.96)',
          borderTop: '1px solid rgba(200,134,26,0.2)',
          backdropFilter: 'blur(10px)',
        }}>
          <button
            onClick={mobileSidebar === 'notes' ? closeMobileSidebar : openMobileNotes}
            style={{
              flex: 1, padding: '0.85rem 0',
              background: mobileSidebar === 'notes' ? 'rgba(200,134,26,0.12)' : 'transparent',
              border: 'none', color: mobileSidebar === 'notes' ? 'var(--gold)' : 'rgba(244,228,193,0.45)',
              fontFamily: "'Lora', serif", fontSize: '0.62rem', letterSpacing: '0.18em',
              textTransform: 'uppercase', cursor: 'pointer',
              display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '0.25rem',
            }}
          >
            <BookOutlined style={{ fontSize: 18 }} />
            Notes
          </button>
          <button
            onClick={mobileSidebar === 'messages' ? closeMobileSidebar : openMobileMessages}
            style={{
              flex: 1, padding: '0.85rem 0',
              background: mobileSidebar === 'messages' ? 'rgba(200,134,26,0.12)' : 'transparent',
              border: 'none', color: mobileSidebar === 'messages' ? 'var(--gold)' : 'rgba(244,228,193,0.45)',
              fontFamily: "'Lora', serif", fontSize: '0.62rem', letterSpacing: '0.18em',
              textTransform: 'uppercase', cursor: 'pointer',
              display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '0.25rem',
            }}
          >
            <MessageOutlined style={{ fontSize: 18 }} />
            Messages
          </button>
        </div>
      )}
    </Layout>
  );
}
