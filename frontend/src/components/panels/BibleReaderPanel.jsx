import React, { useState, useRef, useEffect, useLayoutEffect, useCallback } from 'react';
import BibleNavigator  from '../BibleNavigator.jsx';
import BibleCard       from '../BibleCard.jsx';
import BookmarkButton  from '../BookmarkButton.jsx';
import HighlightPicker from '../HighlightPicker.jsx';
import { useBibleReaderPanel } from '../../context/ReaderPanelContexts.jsx';
import { VerseAskMenu, VerseAskOverlay } from '../VerseAskAi.jsx';
import { verseContextFromSpan } from '../../lib/verseAsk.js';

const FONT_SIZES = [
  { size: '1.08rem', lineHeight: '1.9'  },
  { size: '1.22rem', lineHeight: '1.85' },
  { size: '1.4rem',  lineHeight: '1.8'  },
];
const FONT_SIZE_LABELS = ['Default', 'Large', 'Largest'];

// Dockview panel: Bible reading. Bundles the book/chapter nav, font-size
// ticker, and bookmarks widget in its own component tree (rather than a
// separate layout region) so they always travel with the reader wherever
// it's docked — dockview only ever has to move this one panel.
export default function BibleReaderPanel() {
  const {
    user, curBook, curChapter, curVerse,
    books, chapterHTML, loading, loadError, preamble,
    getChapterCount, verseCount,
    onNavigate, onPrev, onNext, onVerseSelected,
    applyHighlights, setHighlight, clearHighlight,
    bookmarks, addBookmark, removeBookmark,
    onShareVerse, askAiEnabled,
  } = useBibleReaderPanel() || {};

  const scrollRef   = useRef(null);
  const lastSpanRef = useRef(null);

  const [pickerVisible, setPickerVisible] = useState(false);
  const [pickerPos,     setPickerPos]     = useState({ x: 0, y: 0 });
  const [selectedVerse, setSelectedVerse] = useState(null);
  // Per-verse Ask AI: right-click menu, then a fixed overlay (never in flow).
  const [verseMenu, setVerseMenu] = useState(null); // { x, y, span }
  const [verseAsk,  setVerseAsk]  = useState(null); // { reference, text, verseNum, anchor }

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

  // Close the highlight picker on any outside click.
  useEffect(() => {
    const hide = () => { setPickerVisible(false); lastSpanRef.current?.classList.remove('active'); lastSpanRef.current = null; };
    document.addEventListener('click', hide);
    return () => document.removeEventListener('click', hide);
  }, []);

  // A chapter/book change invalidates any open picker for the old verse span
  // (mirrors the reset handleNavigate/handleNavigateVerse used to do directly
  // when this state lived in Reader.jsx).
  useEffect(() => {
    setPickerVisible(false);
    lastSpanRef.current?.classList.remove('active');
    lastSpanRef.current = null;
  }, [curBook, curChapter]);

  // Scroll to top synchronously before paint on a new chapter with no target verse.
  // Scrolls this panel's own body — NOT #root, which no longer scrolls once this
  // panel lives inside a bounded dockview cell.
  useLayoutEffect(() => {
    if (!chapterHTML || curVerse) return;
    if (scrollRef.current) scrollRef.current.scrollTop = 0;
  }, [chapterHTML]);

  // Scroll to a specific verse after paint (needs the element in the DOM first).
  useEffect(() => {
    if (!chapterHTML || !curVerse || !scrollRef.current) return;
    const el = document.getElementById(`vs${curVerse}`);
    if (!el) return;
    const offset = el.getBoundingClientRect().top + scrollRef.current.scrollTop - 120;
    scrollRef.current.scrollTop = offset;
  }, [chapterHTML]);

  const handleVerseClick = useCallback((span, vNum, e) => {
    e.stopPropagation();
    if (lastSpanRef.current && lastSpanRef.current !== span) lastSpanRef.current.classList.remove('active');
    span.classList.add('active');
    lastSpanRef.current = span;
    onVerseSelected?.(vNum);
    setSelectedVerse(vNum);
    const rect = span.getBoundingClientRect();
    setPickerPos({ x: Math.max(8, Math.min(rect.left, window.innerWidth - 220)), y: rect.top > 80 ? rect.top - 52 : rect.bottom + 8 });
    setPickerVisible(true);
  }, [onVerseSelected]);

  const openVerseMenu = useCallback((span, x, y) => {
    setPickerVisible(false);
    setVerseMenu({ x, y, span });
  }, []);

  // Right-click on a verse. Only takes over when Ask AI is available, signed in
  // and there is no active text selection or link, so otherwise the native
  // menu (copy etc.) is untouched.
  const handleContextMenu = useCallback((e) => {
    if (!askAiEnabled || !user) return;
    const span = e.target.closest?.('.verse-span');
    if (!span || !span.id?.startsWith('vs') || e.target.closest('a[href]')) return;
    const sel = window.getSelection?.();
    if (sel && !sel.isCollapsed && String(sel).trim()) return;
    e.preventDefault();
    openVerseMenu(span, e.clientX, e.clientY);
  }, [askAiEnabled, user, openVerseMenu]);

  // Keyboard equivalent: ContextMenu key / Shift+F10 on the selected verse.
  useEffect(() => {
    if (!askAiEnabled || !user) return undefined;
    const onKey = (e) => {
      if (e.key !== 'ContextMenu' && !(e.shiftKey && e.key === 'F10')) return;
      const span = lastSpanRef.current;
      const ae = document.activeElement;
      if (!span || !span.isConnected || (ae && ae !== document.body && /^(INPUT|TEXTAREA|SELECT)$/.test(ae.tagName))) return;
      e.preventDefault();
      const r = span.getBoundingClientRect();
      openVerseMenu(span, r.left + 16, r.bottom);
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [askAiEnabled, user, openVerseMenu]);

  const startVerseAsk = useCallback(() => {
    const span = verseMenu?.span;
    setVerseMenu(null);
    if (!span || !span.isConnected) return;
    const { verseNum, reference, text } = verseContextFromSpan(span, curBook, curChapter);
    if (!text) return;
    const v = span.getBoundingClientRect();
    const col = (span.closest('.card-body') || span).getBoundingClientRect();
    setVerseAsk({
      reference, text, verseNum,
      anchor: { verse: { top: v.top, bottom: v.bottom }, column: { left: col.left, width: col.width } },
    });
  }, [verseMenu, curBook, curChapter]);

  const closeVerseMenu = useCallback(() => setVerseMenu(null), []);
  const closeVerseAsk  = useCallback(() => setVerseAsk(null), []);

  // A chapter change makes the captured anchor meaningless.
  useEffect(() => { setVerseAsk(null); setVerseMenu(null); }, [curBook, curChapter]);

  const handleHighlightColor = useCallback(async (color) => {
    if (!selectedVerse) return;
    await setHighlight?.(selectedVerse, color);
    setPickerVisible(false);
    lastSpanRef.current?.classList.remove('active'); lastSpanRef.current = null;
  }, [selectedVerse, setHighlight]);

  const handleClearHighlight = useCallback(async () => {
    if (!selectedVerse) return;
    await clearHighlight?.(selectedVerse);
    setPickerVisible(false);
    lastSpanRef.current?.classList.remove('active'); lastSpanRef.current = null;
  }, [selectedVerse, clearHighlight]);

  const handleShareVerse = useCallback(() => {
    if (!selectedVerse || !onShareVerse) return;
    onShareVerse(curBook, curChapter, selectedVerse);
    setPickerVisible(false);
    lastSpanRef.current?.classList.remove('active'); lastSpanRef.current = null;
  }, [selectedVerse, onShareVerse, curBook, curChapter]);

  const chCount = getChapterCount ? getChapterCount(curBook) : 0;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', overflow: 'hidden' }}>
      <div className="bible-panel-toolbar">
        <BibleNavigator
          books={books || []} curBook={curBook} curChapter={curChapter}
          onNavigate={onNavigate} chapterCount={getChapterCount}
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
          bookmarks={bookmarks || {}}
          curBook={curBook}
          curChapter={curChapter}
          onAdd={addBookmark}
          onRemove={removeBookmark}
          onNavigate={onNavigate}
        />
      </div>

      <div ref={scrollRef} className="bible-panel-body">
        <BibleCard
          loading={loading} loadError={loadError}
          curBook={curBook} curChapter={curChapter}
          chapterHTML={chapterHTML} chapterCount={chCount}
          preamble={preamble}
          onPrev={onPrev} onNext={onNext}
          onVerseClick={handleVerseClick}
          applyHighlights={applyHighlights}
          onVerseContextMenu={handleContextMenu}
        />
      </div>

      <HighlightPicker
        visible={pickerVisible} position={pickerPos}
        onColor={handleHighlightColor} onClear={handleClearHighlight}
        onShare={onShareVerse ? handleShareVerse : undefined}
      />

      {verseMenu && <VerseAskMenu x={verseMenu.x} y={verseMenu.y} onPick={startVerseAsk} onClose={closeVerseMenu} />}
      {verseAsk && (
        <VerseAskOverlay
          userId={user?.user_id} reference={verseAsk.reference} verseText={verseAsk.text}
          verseNum={verseAsk.verseNum} anchor={verseAsk.anchor} onClose={closeVerseAsk}
        />
      )}
    </div>
  );
}
