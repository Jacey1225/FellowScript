import React, { useEffect, useLayoutEffect, useState, useRef, useCallback, useMemo } from 'react';
import { useSearchParams } from 'react-router-dom';
import { Layout } from 'antd';
import { DockviewReact } from 'dockview-react';

import AppNav           from '../components/AppNav.jsx';
import AppBloom         from '../components/AppBloom.jsx';
import SessionCreator  from '../components/SessionCreator.jsx';

import BibleReaderPanelComponent from '../components/panels/BibleReaderPanel.jsx';
import NotesPanelComponent       from '../components/panels/NotesPanel.jsx';
import HighlightsPanelComponent  from '../components/panels/HighlightsPanel.jsx';
import MessagingPanelComponent   from '../components/panels/MessagingPanel.jsx';
import AgentChatPanelComponent   from '../components/panels/AgentChatPanel.jsx';
import ReaderDockRail             from '../components/panels/ReaderDockRail.jsx';
import {
  BibleReaderPanelContext, NotesPanelContext, HighlightsPanelContext,
  MessagingPanelContext, AgentChatPanelContext,
} from '../context/ReaderPanelContexts.jsx';
import {
  PANEL_IDS, loadSavedLayout, buildDefaultLayout, saveLayout, reopenPanel,
} from '../lib/readerDockLayout.js';

import { useAuth }        from '../context/AuthContext.jsx';
import { useAgentChat }  from '../hooks/useAgentChat.js';
import { useBible }       from '../hooks/useBible.js';
import { useHighlights }  from '../hooks/useHighlights.js';
import { useNotes }       from '../hooks/useNotes.js';
import { useMessaging }   from '../hooks/useMessaging.js';
import { useSessions }    from '../hooks/useSessions.js';
import { useBookmarks }   from '../hooks/useBookmarks.js';

// Registered once — dockview looks panels up by this id, matching PANEL_IDS.
const PANEL_COMPONENTS = {
  [PANEL_IDS.BIBLE]:      BibleReaderPanelComponent,
  [PANEL_IDS.NOTES]:      NotesPanelComponent,
  [PANEL_IDS.HIGHLIGHTS]: HighlightsPanelComponent,
  [PANEL_IDS.MESSAGING]:  MessagingPanelComponent,
  [PANEL_IDS.AGENT_CHAT]: AgentChatPanelComponent,
};

// ── Main Reader ───────────────────────────────────────────────────────────────
// Desktop-only. Mobile devices are turned away before this ever mounts (see
// MobileBlockGate in App.jsx) — this used to also carry a parallel mobile
// bottom-tab-bar/overlay layout (dockview doesn't work in a hidden/zero-size
// container), which is why some of the state below only ever fed the desktop
// dockview panels even though a couple of hooks still read a bit oddly.

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
    requestUploadUrl, uploadToS3, searchGifs,
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
  // Left dock rail (item 3) — which panel ids are currently present in the
  // live layout, and which one is active/visible; kept as component state
  // (rather than read imperatively) so the rail re-renders on every
  // dockview panel add/remove/activate. railDisposablesRef holds the three
  // DockviewApi subscriptions this drives, disposed alongside the existing
  // layout-change one on unmount/re-ready.
  const [openPanelIds, setOpenPanelIds]   = useState(() => new Set());
  const [activePanelId, setActivePanelId] = useState(null);
  const railDisposablesRef = useRef([]);

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
  }, []);

  useEffect(() => {
    if (user) { loadHighlights(); loadNotes(); loadGroups(); loadBookmarks(); connectWS(); loadAgents(); }
    return () => disconnectWS();
  }, [user]);

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
  }, [user, groups]);

  useEffect(() => {
    if (!curBook) return;
    const params = { book: curBook };
    if (curChapter) params.ch = curChapter;
    if (curVerse)   params.vs = curVerse;
    setSearchParams(params, { replace: true });
  }, [curBook, curChapter, curVerse]);

  useEffect(() => { setChapterRenderedCallback(() => loadHighlights()); }, [setChapterRenderedCallback, loadHighlights]);

  // Disable browser scroll restoration so it can't fight our programmatic scrolls
  useEffect(() => {
    if ('scrollRestoration' in history) history.scrollRestoration = 'manual';
  }, []);

  // Scroll to top synchronously before paint whenever a new chapter loads without a target verse.
  useLayoutEffect(() => {
    if (!chapterHTML || curVerse) return;
    const root = document.getElementById('root');
    if (root) root.scrollTop = 0;
  }, [chapterHTML]);

  // Scroll to a specific verse after paint (needs the element in the DOM first)
  useEffect(() => {
    if (!chapterHTML || !curVerse) return;
    const el = document.getElementById(`vs${curVerse}`);
    if (!el) return;
    const root = document.getElementById('root');
    const offset = el.getBoundingClientRect().top + (root ? root.scrollTop : window.scrollY) - 120;
    if (root) root.scrollTop = offset;
    else window.scrollTo({ top: offset, behavior: 'smooth' });
  }, [chapterHTML]);

  // Clean up the dockview layout-change + rail subscriptions on unmount.
  useEffect(() => {
    return () => {
      disposableRef.current?.dispose();
      railDisposablesRef.current.forEach(d => d?.dispose());
      if (saveTimerRef.current) clearTimeout(saveTimerRef.current);
    };
  }, []);

  // ── Handlers ────────────────────────────────────────────────────────────────
  const handleNavigate = useCallback((book, ch) => {
    setBook(book);
    setChapter(ch, book, null);
    setCurVerse(null);
  }, [setBook, setChapter]);

  const handleNavigateVerse = useCallback((book, ch, vs) => {
    setBook(book);
    setChapter(ch, book, null);
    setCurVerse(vs);
  }, [setBook, setChapter]);

  const getChapterCount = useCallback((book) => chapterCount(book, null), [chapterCount]);

  const handlePrev = useCallback(() => { if (curChapter > 1) { setChapter(curChapter - 1, null, null); setCurVerse(null); } }, [curChapter, setChapter]);
  const handleNext = useCallback(() => { const mx = chapterCount(curBook, null); if (curChapter < mx) { setChapter(curChapter + 1, null, null); setCurVerse(null); } }, [curBook, curChapter, chapterCount, setChapter]);

  const handleGroupChange = useCallback(async (groupId) => {
    await selectGroup(groupId, async (gid) => { if (gid) await loadGroupHighlights(gid); else clearGroupHighlights(); });
  }, [selectGroup, loadGroupHighlights, clearGroupHighlights]);

  const handleLoadContacts = useCallback(async () => { await loadContacts(); setContactsLoaded(true); }, [loadContacts]);

  const handleOpenChat = useCallback(async (contact) => {
    closeAgentChat();
    await openChat(contact);
    loadSessions(contact);
  }, [openChat, loadSessions, closeAgentChat]);

  const handleCloseChat = useCallback(() => { closeChat(); }, [closeChat]);

  const handleOpenAgent = useCallback(async (agent) => {
    closeChat();
    await openAgentChat(agent);
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

    // Left dock rail (item 3) — mirror the live layout's open panels +
    // active panel into React state so the rail re-renders on every add/
    // remove/activate. Synced once eagerly (covers the just-loaded/built
    // layout) plus on every subsequent lifecycle event.
    const syncOpenPanels = () => setOpenPanelIds(new Set(api.panels.map(p => p.id)));
    syncOpenPanels();
    setActivePanelId(api.activePanel?.id ?? null);
    railDisposablesRef.current.forEach(d => d?.dispose());
    railDisposablesRef.current = [
      api.onDidAddPanel(syncOpenPanels),
      api.onDidRemovePanel(syncOpenPanels),
      api.onDidActivePanelChange((e) => setActivePanelId(e?.panel?.id ?? null)),
    ];
  }, []);

  // Rail icon click: activate the panel if it's already open (including a
  // backgrounded tab, e.g. Highlights/Messages tabbed behind Notes), else
  // reopen it in a sensible default position — this single entry point
  // satisfies both "reveal" and "reopen" per the request's own framing
  // ("when a user exits from one tab, they can pull it back up").
  const handleRailSelect = useCallback((id) => {
    const api = dockviewApiRef.current;
    if (!api) return;
    const panel = api.getPanel(id);
    if (panel) panel.api.setActive();
    else reopenPanel(api, id);
  }, []);

  // ── Derived ─────────────────────────────────────────────────────────────────
  const preamble = getPreamble(curBook, null);
  const chCount  = chapterCount(curBook, null);
  const notesData = { all: allNotes, filtered: filteredNotes, group: groupNotes, filteredGroup };

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
    onRequestUploadUrl: requestUploadUrl, onUploadToS3: uploadToS3, onSearchGifs: searchGifs,
    sessions, activeSessionId, talkingUserId,
    onJoinSession: joinSession, onLeaveSession: handleLeaveSession,
    onOpenSessionCreator: () => openCreator(), onEditSession: openCreator, onDeleteSession: deleteSession,
    onNavigateVerse: handleNavigateVerse,
    videoEnabled, videoTiles, onToggleVideo: toggleVideo, bindVideoTile,
  }), [user, friends, msgGroups, currentContact, messages, groupMembers, handleOpenChat, handleCloseChat,
       addFriend, removeFriend, reportUser, blockUser, createGroup, updateGroup, leaveGroup,
       contactsLoaded, handleLoadContacts, sendMessage, requestUploadUrl, uploadToS3, searchGifs,
       sessions, activeSessionId, talkingUserId,
       joinSession, handleLeaveSession, openCreator, deleteSession, handleNavigateVerse,
       videoEnabled, videoTiles, toggleVideo, bindVideoTile]);

  const agentChatPanelValue = useMemo(() => ({
    user, agents, agentMessages, activeAgent, agentThinking,
    onOpenAgent: handleOpenAgent, onCloseAgent: handleCloseAgent, onNewAgent: handleNewAgent,
    sendAgentMessage,
    curBook, curChapter, curVerse, allNotes, onNavigateVerse: handleNavigateVerse,
  }), [user, agents, agentMessages, activeAgent, agentThinking, handleOpenAgent, handleCloseAgent,
       handleNewAgent, sendAgentMessage, curBook, curChapter, curVerse, allNotes, handleNavigateVerse]);

  return (
    <BibleReaderPanelContext.Provider value={bibleReaderPanelValue}>
    <NotesPanelContext.Provider value={notesPanelValue}>
    <HighlightsPanelContext.Provider value={highlightsPanelValue}>
    <MessagingPanelContext.Provider value={messagingPanelValue}>
    <AgentChatPanelContext.Provider value={agentChatPanelValue}>
      <Layout style={{ minHeight: '100vh', background: 'transparent', overflow: 'hidden' }}>
        <AppBloom variant="reader" />
        <AppNav />

        <ReaderDockRail
          openPanelIds={openPanelIds}
          activePanelId={activePanelId}
          onSelect={handleRailSelect}
        />
        <div className="reader-dock-container dockview-theme-abyss">
          <DockviewReact
            components={PANEL_COMPONENTS}
            onReady={handleDockviewReady}
            disableFloatingGroups
          />
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
    </AgentChatPanelContext.Provider>
    </MessagingPanelContext.Provider>
    </HighlightsPanelContext.Provider>
    </NotesPanelContext.Provider>
    </BibleReaderPanelContext.Provider>
  );
}
