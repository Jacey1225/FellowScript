import React, { useState, useEffect, useCallback } from 'react';
import { Modal, Segmented, Button } from 'antd';
import { SearchOutlined, RightOutlined } from '@ant-design/icons';
import AgentChatThread from './AgentChatThread.jsx';

const NT_FIRST = 'Matthew';

// Duplicated in-file rather than shared with BibleNavigator.jsx/VerseSelector.jsx —
// those two components already duplicate the same small section renderer
// independently, so a third private copy here matches the existing convention
// rather than introducing a new shared module for it.
function JumpBooksSection({ label, books, selected, onSelect }) {
  return (
    <>
      <div className="bib-section-label">{label}</div>
      <div className="bib-books-grid">
        {books.map(book => (
          <button
            key={book}
            className={`bib-book-btn${selected === book ? ' active' : ''}`}
            onClick={() => onSelect(book)}
          >
            {book}
          </button>
        ))}
      </div>
    </>
  );
}

// "Jump to passage" mode — a 3-column book/chapter/verse picker built from the
// same real chrome classes BibleNavigator.jsx/VerseSelector.jsx already use
// (.bib-section-label/.bib-books-grid/.bib-book-btn/.bib-ch-grid/.bib-ch-btn),
// rather than a new free-text reference parser (no such parsing utility
// exists in the codebase to reuse, and the app's one real "pick a passage"
// convention is this grid picker). Wires to the existing handleNavigate
// (book+chapter only) and handleNavigateVerse (book+chapter+verse) handlers.
function JumpPassagePanel({ books, curBook, curChapter, chapterCount, verseCount, onNavigate, onNavigateVerse, onDone }) {
  const [selBook, setSelBook] = useState(curBook || null);
  const [selCh,   setSelCh]   = useState(curBook ? curChapter : null);

  useEffect(() => {
    if (curBook) { setSelBook(curBook); setSelCh(curChapter || null); }
  }, [curBook, curChapter]);

  const ntIdx   = books.indexOf(NT_FIRST);
  const otBooks = ntIdx >= 0 ? books.slice(0, ntIdx) : books;
  const ntBooks = ntIdx >= 0 ? books.slice(ntIdx)    : [];

  const chCount = selBook ? chapterCount(selBook) : 0;
  const vsCount = (selBook && selCh) ? verseCount(selBook, selCh) : 0;

  const handleBookSelect  = (book) => { setSelBook(book); setSelCh(null); };
  const handleGoToChapter = () => { if (selBook && selCh) { onNavigate(selBook, selCh); onDone(); } };
  const handleVerseSelect = (vs) => { onNavigateVerse(selBook, selCh, vs); onDone(); };

  return (
    <div className="cmd-jump-cols">
      <div className="cmd-jump-col">
        <JumpBooksSection label="Old Testament" books={otBooks} selected={selBook} onSelect={handleBookSelect} />
        <JumpBooksSection label="New Testament" books={ntBooks} selected={selBook} onSelect={handleBookSelect} />
      </div>

      <div className="cmd-jump-col">
        {!selBook ? (
          <div className="cmd-jump-hint">Select a book</div>
        ) : (
          <>
            <div className="bib-ch-book-label">{selBook}</div>
            <div className="bib-ch-grid">
              {Array.from({ length: chCount }, (_, i) => i + 1).map(ch => (
                <button key={ch} className={`bib-ch-btn${selCh === ch ? ' active' : ''}`} onClick={() => setSelCh(ch)}>
                  {ch}
                </button>
              ))}
            </div>
            <Button
              type="primary"
              size="small"
              disabled={!selCh}
              onClick={handleGoToChapter}
              icon={<RightOutlined style={{ fontSize: '0.6rem' }} />}
              style={{ marginTop: '0.75rem' }}
            >
              Go to chapter
            </Button>
          </>
        )}
      </div>

      <div className="cmd-jump-col">
        {!selCh ? (
          <div className="cmd-jump-hint">Pick a chapter, then optionally a verse</div>
        ) : (
          <>
            <div className="bib-ch-book-label">{selBook} {selCh}</div>
            <div className="bib-ch-grid">
              {Array.from({ length: vsCount }, (_, i) => i + 1).map(vs => (
                <button key={vs} className="bib-ch-btn" onClick={() => handleVerseSelect(vs)}>
                  {vs}
                </button>
              ))}
            </div>
          </>
        )}
      </div>
    </div>
  );
}

// The header's "Jump or Ask" ⌘K command-trigger (design-spec §3.2) and its
// segmented Jump/Ask overlay (§3.3) — the one genuinely new interactive
// surface in this restyle pass (see intake-spec.md). Mounted by AppNav.jsx
// only on the Reader route, driven entirely by props Reader.jsx already
// derives from its own hooks — no new data fetching or endpoints here.
export default function CommandTrigger({
  books, curBook, curChapter, chapterCount, verseCount, onNavigate, onNavigateVerse,
  user, agents, activeAgent, agentMessages, agentThinking, onOpenAgent, onNewAgent, sendAgentMessage,
  curVerse, allNotes,
}) {
  const [open, setOpen] = useState(false);
  const [mode, setMode] = useState('jump');

  const handleClose = useCallback(() => setOpen(false), []);

  // ⌘K / Ctrl+K toggles the overlay from anywhere on the Reader page. Safe to
  // listen globally since this component only mounts on the Reader route.
  useEffect(() => {
    const handler = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        setOpen(v => !v);
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, []);

  // Open question 3 (intake-spec.md), resolved here per useAgentChat's real
  // API: "Ask the agent" reuses the same pinned session — activeAgent /
  // agentMessages / sendAgentMessage from useAgentChat — rather than a
  // lighter ephemeral call. useAgentChat's only send path is the WebSocket
  // connection opened by openAgentChat; there's no separate stateless
  // request/response endpoint to call instead, so a true ephemeral mode
  // would mean inventing a parallel messaging path the hook doesn't offer
  // (out of scope — "no new backend endpoints... consuming functionality
  // that already exists"). Seed an agent the first time Ask mode is opened
  // with nothing already active, using the same "first enabled agent"
  // convention Reader.jsx's handleLeaveSession already applies.
  useEffect(() => {
    if (!open || mode !== 'ask' || activeAgent) return;
    if (agents?.length) {
      onOpenAgent(agents.find(a => a.enabled !== false) || agents[0]);
    } else {
      onNewAgent();
    }
  }, [open, mode, activeAgent, agents, onOpenAgent, onNewAgent]);

  return (
    <>
      <button
        className={`nav-pill-btn cmd-trigger-btn${open ? ' open' : ''}`}
        onClick={() => setOpen(true)}
        title="Jump or Ask (⌘K)"
      >
        <SearchOutlined style={{ fontSize: '0.72rem' }} />
        <span>Jump or Ask</span>
        <span className="cmd-trigger-kbd">⌘K</span>
      </button>

      <Modal
        open={open}
        onCancel={handleClose}
        footer={null}
        closable={false}
        width={640}
        className="cmd-overlay"
        styles={{
          mask: { background: 'rgba(0,0,0,0.55)' },
          content: {
            background: 'var(--widget-bg)',
            border: '1px solid var(--widget-border)',
            borderRadius: 'var(--radius-lg)',
            backdropFilter: 'blur(20px)',
            padding: 0,
            overflow: 'hidden',
          },
          body: { padding: 0 },
        }}
      >
        <div className="cmd-overlay-header">
          <Segmented
            options={[
              { label: 'Jump to passage', value: 'jump' },
              { label: 'Ask the agent',   value: 'ask'  },
            ]}
            value={mode}
            onChange={setMode}
          />
        </div>

        <div className="cmd-overlay-body">
          {mode === 'jump' ? (
            <JumpPassagePanel
              books={books} curBook={curBook} curChapter={curChapter}
              chapterCount={chapterCount} verseCount={verseCount}
              onNavigate={onNavigate} onNavigateVerse={onNavigateVerse}
              onDone={handleClose}
            />
          ) : (
            <AgentChatThread
              agent={activeAgent}
              messages={agentMessages}
              user={user}
              onBack={handleClose}
              onSend={sendAgentMessage}
              agentThinking={agentThinking}
              curBook={curBook}
              curChapter={curChapter}
              curVerse={curVerse}
              allNotes={allNotes}
              onNavigateVerse={onNavigateVerse}
            />
          )}
        </div>
      </Modal>
    </>
  );
}
