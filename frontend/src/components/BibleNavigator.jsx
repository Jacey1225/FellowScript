import React, { useState, useEffect, useRef } from 'react';
import { createPortal } from 'react-dom';
import { BookOutlined, DownOutlined } from '@ant-design/icons';

const NT_FIRST = 'Matthew';

function BooksSection({ label, books, selected, onSelect }) {
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

export default function BibleNavigator({ books, curBook, curChapter, onNavigate, chapterCount }) {
  const [open,         setOpen]         = useState(false);
  const [selectedBook, setSelectedBook] = useState(curBook || null);
  const [widgetPos,    setWidgetPos]    = useState({ top: 0, left: 0, width: 680 });
  const widgetRef = useRef(null);
  const pillRef   = useRef(null);

  // Keep selectedBook in sync when navigating externally (e.g. prev/next buttons)
  useEffect(() => { if (curBook) setSelectedBook(curBook); }, [curBook]);

  // Close on outside click
  useEffect(() => {
    if (!open) return;
    const handle = (e) => {
      if (!widgetRef.current?.contains(e.target) && !pillRef.current?.contains(e.target)) {
        setOpen(false);
      }
    };
    document.addEventListener('mousedown', handle);
    return () => document.removeEventListener('mousedown', handle);
  }, [open]);

  // Rendered via a body portal at a viewport-fixed position (computed from the
  // pill button) so the widget is never clipped by a dockable panel's own
  // overflow:hidden content area. Mirrors the mobile-vs-desktop width the CSS
  // media query used to apply, since the inline width now takes precedence.
  const handleToggle = () => {
    if (!open && pillRef.current) {
      const rect = pillRef.current.getBoundingClientRect();
      const mob   = window.innerWidth <= 1024;
      const width = mob ? window.innerWidth - 20 : Math.min(680, window.innerWidth - 24);
      const left  = mob ? 10 : Math.max(8, Math.min(rect.left, window.innerWidth - width - 8));
      setWidgetPos({ top: rect.bottom + 2, left, width });
    }
    setOpen(v => !v);
  };

  // Split books into OT / NT
  const ntIdx  = books.indexOf(NT_FIRST);
  const otBooks = ntIdx >= 0 ? books.slice(0, ntIdx) : books;
  const ntBooks = ntIdx >= 0 ? books.slice(ntIdx)   : [];

  const chCount = selectedBook ? chapterCount(selectedBook) : 0;

  const pillLabel = curBook && curChapter
    ? `${curBook}  ·  ${curChapter}`
    : curBook || 'Select Passage';

  return (
    <div style={{ position: 'relative' }}>
      {/* Pill button */}
      <button
        ref={pillRef}
        className={`nav-pill-btn${open ? ' open' : ''}`}
        onClick={handleToggle}
      >
        <BookOutlined style={{ fontSize: '0.72rem' }} />
        <span>{pillLabel}</span>
        <DownOutlined style={{
          fontSize: '0.6rem', opacity: 0.55,
          transform: open ? 'rotate(180deg)' : 'rotate(0deg)',
          transition: 'transform 0.2s',
        }} />
      </button>

      {/* Navigation widget */}
      {open && createPortal(
        <div ref={widgetRef} className="bib-nav-widget"
          style={{ position: 'fixed', top: widgetPos.top, left: widgetPos.left, width: widgetPos.width }}>

          {/* Left: Books */}
          <div className="bib-nav-books">
            <BooksSection
              label="New Testament"
              books={ntBooks}
              selected={selectedBook}
              onSelect={setSelectedBook}
            />
            <BooksSection
              label="Old Testament"
              books={otBooks}
              selected={selectedBook}
              onSelect={setSelectedBook}
            />
          </div>

          {/* Right: Chapters */}
          <div className="bib-nav-chapters">
            {!selectedBook ? (
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100%', padding: '1rem' }}>
                <span style={{ fontSize: '0.72rem', color: 'rgba(200,134,26,0.35)', fontFamily: "'Inter', sans-serif", textAlign: 'center', lineHeight: 1.6 }}>
                  Select a book to see its chapters
                </span>
              </div>
            ) : (
              <>
                <div className="bib-ch-book-label">{selectedBook}</div>
                <div className="bib-ch-grid">
                  {Array.from({ length: chCount }, (_, i) => i + 1).map(ch => (
                    <button
                      key={ch}
                      className={`bib-ch-btn${curBook === selectedBook && curChapter === ch ? ' active' : ''}`}
                      onClick={() => { onNavigate(selectedBook, ch); setOpen(false); }}
                    >
                      {ch}
                    </button>
                  ))}
                </div>
              </>
            )}
          </div>

        </div>,
        document.body
      )}
    </div>
  );
}
