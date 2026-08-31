import React, { useState, useRef, useEffect, useLayoutEffect, useCallback } from 'react';
import BibleNavigator  from '../BibleNavigator.jsx';
import BibleCard       from '../BibleCard.jsx';
import BookmarkButton  from '../BookmarkButton.jsx';
import HighlightPicker from '../HighlightPicker.jsx';
import { useBibleReaderPanel } from '../../context/ReaderPanelContexts.jsx';

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
  } = useBibleReaderPanel() || {};

  const scrollRef   = useRef(null);
  const lastSpanRef = useRef(null);

  const [pickerVisible, setPickerVisible] = useState(false);
  const [pickerPos,     setPickerPos]     = useState({ x: 0, y: 0 });
  const [selectedVerse, setSelectedVerse] = useState(null);

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
        />
      </div>

      <HighlightPicker
        visible={pickerVisible} position={pickerPos}
        onColor={handleHighlightColor} onClear={handleClearHighlight}
      />
    </div>
  );
}
