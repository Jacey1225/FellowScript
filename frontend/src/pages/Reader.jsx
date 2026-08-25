import React, { useEffect, useLayoutEffect, useState, useRef, useCallback, useMemo } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Layout, Typography } from 'antd';
import { MessageOutlined, BookOutlined, ReloadOutlined } from '@ant-design/icons';
import { DockviewReact } from 'dockview-react';

import AppNav           from '../components/AppNav.jsx';
import AppBloom         from '../components/AppBloom.jsx';
import BibleNavigator  from '../components/BibleNavigator.jsx';
import BibleCard       from '../components/BibleCard.jsx';
import NotesSidebar    from '../components/NotesSidebar.jsx';
import HighlightPicker from '../components/HighlightPicker.jsx';
import SessionCreator  from '../components/SessionCreator.jsx';
import BookmarkButton  from '../components/BookmarkButton.jsx';
import ContactsPanel   from '../components/ContactsPanel.jsx';
import ChatThread       from '../components/ChatThread.jsx';
import AgentChatThread  from '../components/AgentChatThread.jsx';

import BibleReaderPanelComponent from '../components/panels/BibleReaderPanel.jsx';
import NotesPanelComponent       from '../components/panels/NotesPanel.jsx';
import HighlightsPanelComponent  from '../components/panels/HighlightsPanel.jsx';
import MessagingPanelComponent   from '../components/panels/MessagingPanel.jsx';
import AgentChatPanelComponent   from '../components/panels/AgentChatPanel.jsx';
import {
  BibleReaderPanelContext, NotesPanelContext, HighlightsPanelContext,
  MessagingPanelContext, AgentChatPanelContext,
} from '../context/ReaderPanelContexts.jsx';
import {
  PANEL_IDS, loadSavedLayout, buildDefaultLayout, saveLayout, resetLayout,
} from '../lib/readerDockLayout.js';

import { useAuth }        from '../context/AuthContext.jsx';
import { useAgentChat }  from '../hooks/useAgentChat.js';
import { useBible }       from '../hooks/useBible.js';
import { useHighlights }  from '../hooks/useHighlights.js';
import { useNotes }       from '../hooks/useNotes.js';
import { useMessaging }   from '../hooks/useMessaging.js';
import { useSessions }    from '../hooks/useSessions.js';
import { useBookmarks }   from '../hooks/useBookmarks.js';
import { useIsDesktopViewport } from '../hooks/useIsDesktopViewport.js';

const { Text } = Typography;
// Aligned with global.css's `@media (max-width: 1024px)` — the single
// breakpoint that decides desktop-dockview vs. mobile-overlay layout.
const MOBILE_BP = 1024;
function isMobile() { return window.innerWidth <= MOBILE_BP; }

const FONT_SIZES = [
  { size: '1.08rem', lineHeight: '1.9'  },
  { size: '1.22rem', lineHeight: '1.85' },
  { size: '1.4rem',  lineHeight: '1.8'  },
];
const FONT_SIZE_LABELS = ['Default', 'Large', 'Largest'];

// Registered once — dockview looks panels up by this id, matching PANEL_IDS.
const PANEL_COMPONENTS = {
  [PANEL_IDS.BIBLE]:      BibleReaderPanelComponent,
  [PANEL_IDS.NOTES]:      NotesPanelComponent,
  [PANEL_IDS.HIGHLIGHTS]: HighlightsPanelComponent,
  [PANEL_IDS.MESSAGING]:  MessagingPanelComponent,
  [PANEL_IDS.AGENT_CHAT]: AgentChatPanelComponent,
};

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
  // Highlight-picker popover state — only used by the mobile branch's own
  // inline Bible-reading JSX below; the desktop dockview branch's
  // BibleReaderPanel keeps an independent copy of this same local state,
  // since the two render trees are mutually exclusive (only one is ever
  // mounted at a time) but each needs its own picker/scroll-position state.
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
    reportUser, blockUser,
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

  // Mobile overlay state (unrelated to the desktop dockview layout below)
  const [mobileSidebar, setMobileSidebar] = useState(null); // 'notes' | 'messages' | null
  const isDesktop = useIsDesktopViewport();

  // Bible font size — mobile-branch copy (see note on pickerVisible above).
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

  // Warm Reader-scoped canvas (design-notes.md §8.1, bounce revision) — the
  // `page-reader` class is what paints the color underneath the fixed
  // AppBloom/grain layers (position: fixed, so they composite over
  // whatever body's own background is); global.css's
  // `[data-theme="dark"] body.page-reader` rule reads this class to warm
  // --bg-page/--bg-page-2 for this route only, leaving every other route's
  // --bg-page untouched. Mount/unmount effect so the class never leaks past
  // this page.
  useEffect(() => {
    document.body.classList.add('page-reader');
    return () => document.body.classList.remove('page-reader');
  }, []);

  // Dockview (desktop) — api ref + layout persistence bookkeeping.
  const dockviewApiRef  = useRef(null);
  const disposableRef   = useRef(null);
  const saveTimerRef    = useRef(null);

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
  // #root is the mobile branch's real scroll container; inert on desktop, where
  // the dockview panel manages its own internal scrolling instead.
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

  // Clean up the dockview layout-change subscription on unmount.
  useEffect(() => {
    return () => {
      disposableRef.current?.dispose();
      if (saveTimerRef.current) clearTimeout(saveTimerRef.current);
    };
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

  // ── Dockview (desktop) ────────────────────────────────────────────────────────
  const handleDockviewReady = useCallback((event) => {
    const api = event.api;
    dockviewApiRef.current = api;
    const loaded = loadSavedLayout(api);
    if (!loaded) buildDefaultLayout(api);

    disposableRef.current?.dispose();
    disposableRef.current = api.onDidLayoutChange(() => {
      if (saveTimerRef.current) clearTimeout(saveTimerRef.current);
      saveTimerRef.current = setTimeout(() => saveLayout(api), 400);
    });
  }, []);

  const handleResetLayout = useCallback(() => {
    if (dockviewApiRef.current) resetLayout(dockviewApiRef.current);
  }, []);

  // ── Derived ─────────────────────────────────────────────────────────────────
  const preamble = getPreamble(curBook, null);
  const chCount  = chapterCount(curBook, null);
  const notesData = { all: allNotes, filtered: filteredNotes, group: groupNotes, filteredGroup };

  // Shared notes sidebar props (mobile only — desktop uses NotesPanelContext/HighlightsPanelContext)
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

  // Shared contacts props (mobile only — desktop uses MessagingPanelContext/AgentChatPanelContext)
  const contactsProps = {
    user, friends, groups: msgGroups, currentContact,
    onOpen: handleOpenChat,
    onAddFriend: addFriend, onRemoveFriend: removeFriend,
    onReportUser: reportUser, onBlockUser: blockUser,
    onCreateGroup: createGroup, onUpdateGroup: updateGroup, onLeaveGroup: leaveGroup,
    loaded: contactsLoaded, onLoad: handleLoadContacts,
    agents, activeAgent, onOpenAgent: handleOpenAgent, onNewAgent: handleNewAgent,
  };

  // ── Desktop dockview panel context values ────────────────────────────────────
  const bibleReaderPanelValue = useMemo(() => ({
    user, curBook, curChapter, curVerse,
    books, chapterHTML, loading, loadError, preamble,
    getChapterCount, verseCount,
    onNavigate: handleNavigate, onPrev: handlePrev, onNext: handleNext,
    onVerseSelected: setCurVerse,
    applyHighlights, setHighlight, clearHighlight,
    bookmarks, addBookmark, removeBookmark,
  }), [user, curBook, curChapter, curVerse, books, chapterHTML, loading, loadError, preamble,
       getChapterCount, verseCount, handleNavigate, handlePrev, handleNext,
       applyHighlights, setHighlight, clearHighlight, bookmarks, addBookmark, removeBookmark]);

  const notesPanelValue = useMemo(() => ({
    user, currentGroupId, groups, onGroupChange: handleGroupChange, onNavigateVerse: handleNavigateVerse,
    notesData, groupLoading, filterActive,
    saveNote, deleteNote, postReply, loadDetailReplies,
    applyFilter, clearFilter,
    books, chapterCount: getChapterCount, verseCount,
  }), [user, currentGroupId, groups, handleGroupChange, handleNavigateVerse, notesData, groupLoading,
       filterActive, saveNote, deleteNote, postReply, loadDetailReplies, applyFilter, clearFilter,
       books, getChapterCount, verseCount]);

  const highlightsPanelValue = useMemo(() => ({
    user, currentGroupId, groups, onGroupChange: handleGroupChange, onNavigateVerse: handleNavigateVerse,
    localHl, groupHighlights, groupUsernames,
  }), [user, currentGroupId, groups, handleGroupChange, handleNavigateVerse, localHl, groupHighlights, groupUsernames]);

  const messagingPanelValue = useMemo(() => ({
    user, friends, groups: msgGroups, currentContact, messages, groupMembers,
    onOpen: handleOpenChat, onBack: handleCloseChat,
    onAddFriend: addFriend, onRemoveFriend: removeFriend,
    onReportUser: reportUser, onBlockUser: blockUser,
    onCreateGroup: createGroup, onUpdateGroup: updateGroup, onLeaveGroup: leaveGroup,
    loaded: contactsLoaded, onLoad: handleLoadContacts, sendMessage,
    sessions, activeSessionId, talkingUserId,
    onJoinSession: joinSession, onLeaveSession: handleLeaveSession,
    onOpenSessionCreator: () => openCreator(), onEditSession: openCreator, onDeleteSession: deleteSession,
    onNavigateVerse: handleNavigateVerse,
    videoEnabled, videoTiles, onToggleVideo: toggleVideo, bindVideoTile,
  }), [user, friends, msgGroups, currentContact, messages, groupMembers, handleOpenChat, handleCloseChat,
       addFriend, removeFriend, reportUser, blockUser, createGroup, updateGroup, leaveGroup,
       contactsLoaded, handleLoadContacts, sendMessage, sessions, activeSessionId, talkingUserId,
       joinSession, handleLeaveSession, openCreator, deleteSession, handleNavigateVerse,
       videoEnabled, videoTiles, toggleVideo, bindVideoTile]);

  const agentChatPanelValue = useMemo(() => ({
    user, agents, agentMessages, activeAgent, agentThinking,
    onOpenAgent: handleOpenAgent, onCloseAgent: handleCloseAgent, onNewAgent: handleNewAgent,
    sendAgentMessage,
    curBook, curChapter, curVerse, allNotes, onNavigateVerse: handleNavigateVerse,
  }), [user, agents, agentMessages, activeAgent, agentThinking, handleOpenAgent, handleCloseAgent,
       handleNewAgent, sendAgentMessage, curBook, curChapter, curVerse, allNotes, handleNavigateVerse]);

  // AppNav's "Jump or Ask" command-trigger (design-spec §3.2-3.3) — a thin
  // props bundle handing the header the exact same navigation/agent-chat
  // machinery the dockview panels already use, so the overlay's Jump mode
  // and Ask mode are real, not stubbed. See CommandTrigger.jsx.
  const commandTriggerProps = useMemo(() => ({
    books, curBook, curChapter, chapterCount: getChapterCount, verseCount,
    onNavigate: handleNavigate, onNavigateVerse: handleNavigateVerse,
    user, agents, activeAgent, agentMessages, agentThinking,
    onOpenAgent: handleOpenAgent, onNewAgent: handleNewAgent, sendAgentMessage,
    curVerse, allNotes,
  }), [books, curBook, curChapter, getChapterCount, verseCount, handleNavigate, handleNavigateVerse,
       user, agents, activeAgent, agentMessages, agentThinking, handleOpenAgent, handleNewAgent,
       sendAgentMessage, curVerse, allNotes]);

  return (
    <BibleReaderPanelContext.Provider value={bibleReaderPanelValue}>
    <NotesPanelContext.Provider value={notesPanelValue}>
    <HighlightsPanelContext.Provider value={highlightsPanelValue}>
    <MessagingPanelContext.Provider value={messagingPanelValue}>
    <AgentChatPanelContext.Provider value={agentChatPanelValue}>
      <Layout style={{ minHeight: '100vh', background: 'transparent', overflow: 'hidden' }}>
        <AppBloom variant="reader" />
        <AppNav commandTrigger={commandTriggerProps} />

        {isDesktop ? (
          <>
            <button className="nav-pill-btn dock-reset-btn" onClick={handleResetLayout} title="Reset layout to default">
              <ReloadOutlined style={{ fontSize: '0.72rem' }} />
              <span>Reset Layout</span>
            </button>
            <div className="reader-dock-container dockview-theme-abyss">
              <DockviewReact
                components={PANEL_COMPONENTS}
                onReady={handleDockviewReady}
                disableFloatingGroups
              />
            </div>
          </>
        ) : (
          <>
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
              <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem', padding: '0.9rem 1rem', borderBottom: '1px solid rgba(255,255,255,0.09)', background: 'rgba(6,4,1,0.98)', flexShrink: 0 }}>
                <button onClick={() => setMobileSidebar(null)} style={{ background: 'none', border: 'none', color: 'rgba(255,198,26,0.65)', cursor: 'pointer', fontSize: '1.1rem' }}>✕</button>
                <Text style={{ fontFamily: "'Space Grotesk', sans-serif", fontSize: '1rem', color: 'var(--parchment)' }}>Notes</Text>
              </div>
              <div style={{ flex: 1, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
                <NotesSidebar {...notesSidebarProps} />
              </div>
            </div>

            <div className={`mobile-overlay${mobileSidebar === 'messages' ? ' open' : ''}`}>
              <div style={{ display: 'flex', alignItems: 'center', gap: '0.6rem', padding: '0.9rem 1rem', borderBottom: '1px solid rgba(255,255,255,0.09)', background: 'rgba(6,4,1,0.98)', flexShrink: 0 }}>
                <button onClick={() => setMobileSidebar(null)} style={{ background: 'none', border: 'none', color: 'rgba(255,198,26,0.65)', cursor: 'pointer', fontSize: '1.1rem' }}>✕</button>
                <Text style={{ fontFamily: "'Space Grotesk', sans-serif", fontSize: '1rem', color: 'var(--parchment)' }}>Messages</Text>
              </div>
              <div style={{ flex: 1, minHeight: 0, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
                {activeAgent
                  ? <AgentChatThread
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
                    ? <ChatThread
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
          </>
        )}

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
    </AgentChatPanelContext.Provider>
    </MessagingPanelContext.Provider>
    </HighlightsPanelContext.Provider>
    </NotesPanelContext.Provider>
    </BibleReaderPanelContext.Provider>
  );
}
