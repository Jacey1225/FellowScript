import React, { useState, useEffect, useRef } from 'react';
import { createPortal } from 'react-dom';

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

export default function VerseSelector({ books, chapterCount, verseCount, onSelect }) {
  const [open,     setOpen]     = useState(false);
  const [selBook,  setSelBook]  = useState(null);
  const [selCh,    setSelCh]    = useState(null);
  const [widgetPos, setWidgetPos] = useState({ top: 0, left: 0 });
  const btnRef    = useRef(null);
  const widgetRef = useRef(null);

  useEffect(() => {
    if (!open) return;
    const handle = (e) => {
      if (!widgetRef.current?.contains(e.target) && !btnRef.current?.contains(e.target)) {
        setOpen(false);
      }
    };
    document.addEventListener('mousedown', handle);
    return () => document.removeEventListener('mousedown', handle);
  }, [open]);

  const handleToggle = () => {
    if (!open && btnRef.current) {
      const rect = btnRef.current.getBoundingClientRect();
      setWidgetPos({ top: rect.bottom + 4, left: rect.left });
    }
    setOpen(v => !v);
  };

  const ntIdx   = books.indexOf(NT_FIRST);
  const otBooks = ntIdx >= 0 ? books.slice(0, ntIdx) : books;
  const ntBooks = ntIdx >= 0 ? books.slice(ntIdx)    : [];

  const chCount = selBook ? chapterCount(selBook) : 0;
  const vsCount = (selBook && selCh) ? verseCount(selBook, selCh) : 0;

  const handleBookSelect = (book) => { setSelBook(book); setSelCh(null); };

  const handleVerseSelect = (vs) => {
    onSelect(selBook, selCh, vs);
    setOpen(false);
    setSelBook(null);
    setSelCh(null);
  };

  const emptyHint = (msg) => (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100%', padding: '1rem' }}>
      <span style={{ fontSize: '0.72rem', color: 'rgba(200,134,26,0.35)', fontFamily: "'Lora', serif", textAlign: 'center', lineHeight: 1.6 }}>{msg}</span>
    </div>
  );

  return (
    <div style={{ position: 'relative', display: 'inline-block' }}>
      <button ref={btnRef} className="vs-add-btn" onClick={handleToggle}>
        + Add Verse
      </button>

      {open && createPortal(
        <div
          ref={widgetRef}
          className="bib-nav-widget verse-sel-widget"
          style={{ position: 'fixed', top: widgetPos.top, left: widgetPos.left, zIndex: 9999 }}
        >
          {/* Books */}
          <div className="bib-nav-books">
            <BooksSection label="Old Testament" books={otBooks} selected={selBook} onSelect={handleBookSelect} />
            <BooksSection label="New Testament" books={ntBooks} selected={selBook} onSelect={handleBookSelect} />
          </div>

          {/* Chapters */}
          <div className="bib-nav-chapters">
            {!selBook ? emptyHint('Select a book') : (
              <>
                <div className="bib-ch-book-label">{selBook}</div>
                <div className="bib-ch-grid">
                  {Array.from({ length: chCount }, (_, i) => i + 1).map(ch => (
                    <button
                      key={ch}
                      className={`bib-ch-btn${selCh === ch ? ' active' : ''}`}
                      onClick={() => setSelCh(ch)}
                    >
                      {ch}
                    </button>
                  ))}
                </div>
              </>
            )}
          </div>

          {/* Verses */}
          <div className="bib-nav-verses">
            {!selCh ? emptyHint('Select a chapter') : (
              <>
                <div className="bib-ch-book-label">Ch. {selCh}</div>
                <div className="bib-ch-grid">
                  {Array.from({ length: vsCount }, (_, i) => i + 1).map(vs => (
                    <button
                      key={vs}
                      className="bib-ch-btn"
                      onClick={() => handleVerseSelect(vs)}
                    >
                      {vs}
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
