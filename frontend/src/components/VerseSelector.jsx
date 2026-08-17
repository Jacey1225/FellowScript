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

function BackBtn({ onClick, label }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem', marginBottom: '0.65rem', paddingBottom: '0.4rem', borderBottom: '1px solid var(--bib-divider)', flexShrink: 0 }}>
      <button
        onClick={onClick}
        style={{ background: 'none', border: 'none', color: 'var(--gold)', cursor: 'pointer', fontSize: '0.78rem', padding: '0 4px', fontFamily: "'Inter', sans-serif" }}
      >
        ← Back
      </button>
      <span style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.55rem', letterSpacing: '0.22em', textTransform: 'uppercase', color: 'var(--bib-section-c)' }}>
        {label}
      </span>
    </div>
  );
}

export default function VerseSelector({ books, chapterCount, verseCount, onSelect }) {
  const [open,      setOpen]      = useState(false);
  const [selBook,   setSelBook]   = useState(null);
  const [selCh,     setSelCh]     = useState(null);
  const [widgetPos, setWidgetPos] = useState({ top: 0, left: 0 });
  const [isMob,     setIsMob]     = useState(false);
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
      const mob = window.innerWidth <= 900;
      setIsMob(mob);
      if (mob) {
        setWidgetPos({ top: rect.bottom + 4, left: 10 });
      } else {
        const widgetW = window.innerWidth <= 1299 ? Math.min(780, window.innerWidth - 444) : 780;
        const clampedLeft = Math.max(0, Math.min(rect.left, window.innerWidth - widgetW - 8));
        setWidgetPos({ top: rect.bottom + 4, left: clampedLeft });
      }
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
      <span style={{ fontSize: '0.72rem', color: 'rgba(255,198,26,0.35)', fontFamily: "'Inter', sans-serif", textAlign: 'center', lineHeight: 1.6 }}>{msg}</span>
    </div>
  );

  const widgetStyle = {
    position: 'fixed',
    top: widgetPos.top,
    left: widgetPos.left,
    zIndex: 9999,
    ...(isMob ? { width: window.innerWidth - 20 } : {}),
  };

  return (
    <div style={{ position: 'relative', display: 'inline-block' }}>
      <button ref={btnRef} className="vs-add-btn" onClick={handleToggle}>
        + Add Verse
      </button>

      {open && createPortal(
        <div ref={widgetRef} className="bib-nav-widget verse-sel-widget" style={widgetStyle}>
          {isMob ? (
            /* Mobile: sequential step-by-step */
            <div style={{ display: 'flex', flexDirection: 'column', width: '100%' }}>

              {/* Step 1: Pick a book */}
              {!selBook && (
                <div className="bib-nav-books" style={{ width: '100%', borderRight: 'none', maxHeight: '62vh' }}>
                  <BooksSection label="Old Testament" books={otBooks} selected={selBook} onSelect={handleBookSelect} />
                  <BooksSection label="New Testament" books={ntBooks} selected={selBook} onSelect={handleBookSelect} />
                </div>
              )}

              {/* Step 2: Pick a chapter */}
              {selBook && !selCh && (
                <div className="bib-nav-chapters" style={{ flex: 'none', maxHeight: '62vh' }}>
                  <BackBtn onClick={() => setSelBook(null)} label={selBook} />
                  <div className="bib-ch-grid">
                    {Array.from({ length: chCount }, (_, i) => i + 1).map(ch => (
                      <button key={ch} className="bib-ch-btn" onClick={() => setSelCh(ch)}>{ch}</button>
                    ))}
                  </div>
                </div>
              )}

              {/* Step 3: Pick a verse */}
              {selBook && selCh && (
                <div className="bib-nav-verses" style={{ flex: 'none', maxHeight: '62vh', borderLeft: 'none' }}>
                  <BackBtn onClick={() => setSelCh(null)} label={`Ch. ${selCh}`} />
                  <div className="bib-ch-grid">
                    {Array.from({ length: vsCount }, (_, i) => i + 1).map(vs => (
                      <button key={vs} className="bib-ch-btn" onClick={() => handleVerseSelect(vs)}>{vs}</button>
                    ))}
                  </div>
                </div>
              )}
            </div>
          ) : (
            /* Desktop: 3-column layout */
            <>
              <div className="bib-nav-books">
                <BooksSection label="Old Testament" books={otBooks} selected={selBook} onSelect={handleBookSelect} />
                <BooksSection label="New Testament" books={ntBooks} selected={selBook} onSelect={handleBookSelect} />
              </div>
              <div className="bib-nav-chapters">
                {!selBook ? emptyHint('Select a book') : (
                  <>
                    <div className="bib-ch-book-label">{selBook}</div>
                    <div className="bib-ch-grid">
                      {Array.from({ length: chCount }, (_, i) => i + 1).map(ch => (
                        <button key={ch} className={`bib-ch-btn${selCh === ch ? ' active' : ''}`} onClick={() => setSelCh(ch)}>{ch}</button>
                      ))}
                    </div>
                  </>
                )}
              </div>
              <div className="bib-nav-verses">
                {!selCh ? emptyHint('Select a chapter') : (
                  <>
                    <div className="bib-ch-book-label">Ch. {selCh}</div>
                    <div className="bib-ch-grid">
                      {Array.from({ length: vsCount }, (_, i) => i + 1).map(vs => (
                        <button key={vs} className="bib-ch-btn" onClick={() => handleVerseSelect(vs)}>{vs}</button>
                      ))}
                    </div>
                  </>
                )}
              </div>
            </>
          )}
        </div>,
        document.body
      )}
    </div>
  );
}
