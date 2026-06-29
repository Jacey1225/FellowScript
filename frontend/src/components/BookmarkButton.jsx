import React, { useState, useRef, useEffect } from 'react';
import { ReadOutlined, ReadFilled } from '@ant-design/icons';

// Split a bookmark key like "1 Kings-5" into { book: "1 Kings", chapter: "5" }.
// Uses lastIndexOf so book names containing spaces are handled correctly.
function parseKey(key) {
  const i = key.lastIndexOf('-');
  return { book: key.slice(0, i), chapter: key.slice(i + 1) };
}

export default function BookmarkButton({ user, bookmarks, curBook, curChapter, onAdd, onRemove, onNavigate }) {
  const [open, setOpen] = useState(false);
  const wrapRef = useRef(null);

  const currentKey  = curBook && curChapter ? `${curBook}-${curChapter}` : null;
  const isBookmarked = currentKey != null && Object.prototype.hasOwnProperty.call(bookmarks, currentKey);
  const entries      = Object.entries(bookmarks);

  // Close dropdown on outside click
  useEffect(() => {
    if (!open) return;
    const close = (e) => { if (!wrapRef.current?.contains(e.target)) setOpen(false); };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, [open]);

  if (!user) return null;

  const handleToggleCurrent = () => {
    if (!currentKey) return;
    if (isBookmarked) {
      onRemove(currentKey);
    } else {
      onAdd(curBook, curChapter, `${curBook} ${curChapter}`);
    }
  };

  return (
    <div ref={wrapRef} style={{ position: 'relative', marginLeft: '0.4rem' }}>
      <button
        className={`nav-pill-btn${open || isBookmarked ? ' open' : ''}`}
        onClick={() => setOpen(v => !v)}
        title="Bookmarks"
        style={{ gap: '0.35rem' }}
      >
        {isBookmarked
          ? <ReadFilled    style={{ fontSize: '0.72rem' }} />
          : <ReadOutlined  style={{ fontSize: '0.72rem' }} />
        }
        <span>Bookmarks</span>
        {entries.length > 0 && (
          <span style={{ fontSize: '0.58rem', color: 'var(--gold)', lineHeight: 1 }}>
            {entries.length}
          </span>
        )}
      </button>

      {open && (
        <div style={{
          position: 'absolute',
          top: 'calc(100% + 8px)',
          left: 0,
          minWidth: 210,
          maxWidth: 280,
          background: 'rgba(10,6,1,0.97)',
          border: '1px solid rgba(200,134,26,0.25)',
          borderRadius: 12,
          boxShadow: '0 8px 28px rgba(0,0,0,0.65)',
          zIndex: 200,
          padding: '0.45rem',
          display: 'flex',
          flexDirection: 'column',
          gap: '0.28rem',
        }}>

          {/* Add / remove current page */}
          <button
            onClick={handleToggleCurrent}
            disabled={!currentKey}
            style={{
              background: isBookmarked ? 'rgba(255,90,90,0.08)' : 'rgba(200,134,26,0.1)',
              border: `1px solid ${isBookmarked ? 'rgba(255,90,90,0.28)' : 'rgba(200,134,26,0.28)'}`,
              borderRadius: 8,
              color: isBookmarked ? 'rgba(255,130,130,0.8)' : 'rgba(200,134,26,0.85)',
              cursor: currentKey ? 'pointer' : 'default',
              fontSize: '0.68rem',
              fontFamily: "'Lora', serif",
              padding: '0.28rem 0.6rem',
              textAlign: 'left',
              width: '100%',
              transition: 'background 0.15s, color 0.15s',
            }}
            onMouseEnter={e => {
              if (!currentKey) return;
              e.currentTarget.style.background = isBookmarked ? 'rgba(255,90,90,0.15)' : 'rgba(200,134,26,0.18)';
            }}
            onMouseLeave={e => {
              e.currentTarget.style.background = isBookmarked ? 'rgba(255,90,90,0.08)' : 'rgba(200,134,26,0.1)';
            }}
          >
            {isBookmarked ? '✕  Remove this page' : '＋  Bookmark this page'}
          </button>

          {/* Divider + list */}
          {entries.length > 0 && (
            <>
              <div style={{ height: 1, background: 'rgba(200,134,26,0.12)', margin: '0.05rem 0.1rem' }} />
              <div style={{ display: 'flex', flexDirection: 'column', gap: '0.22rem', maxHeight: 220, overflowY: 'auto' }}>
                {entries.map(([key]) => {
                  const { book, chapter } = parseKey(key);
                  return (
                    <div key={key} style={{ display: 'flex', alignItems: 'center', gap: '0.28rem' }}>
                      <button
                        onClick={() => { onNavigate(book, parseInt(chapter)); setOpen(false); }}
                        style={{
                          flex: 1,
                          background: 'none',
                          border: '1px solid rgba(200,134,26,0.18)',
                          borderRadius: 100,
                          color: 'rgba(244,228,193,0.7)',
                          cursor: 'pointer',
                          fontSize: '0.68rem',
                          fontFamily: "'Lora', serif",
                          padding: '0.2rem 0.65rem',
                          textAlign: 'left',
                          overflow: 'hidden',
                          textOverflow: 'ellipsis',
                          whiteSpace: 'nowrap',
                          transition: 'border-color 0.15s, color 0.15s',
                        }}
                        onMouseEnter={e => { e.currentTarget.style.borderColor = 'rgba(200,134,26,0.5)'; e.currentTarget.style.color = 'var(--gold)'; }}
                        onMouseLeave={e => { e.currentTarget.style.borderColor = 'rgba(200,134,26,0.18)'; e.currentTarget.style.color = 'rgba(244,228,193,0.7)'; }}
                      >
                        {book} {chapter}
                      </button>
                      <button
                        onClick={() => onRemove(key)}
                        title="Remove bookmark"
                        style={{
                          background: 'none', border: 'none',
                          color: 'rgba(200,134,26,0.3)',
                          cursor: 'pointer', fontSize: '0.85rem',
                          padding: '0 3px', lineHeight: 1, flexShrink: 0,
                          transition: 'color 0.15s',
                        }}
                        onMouseEnter={e => { e.currentTarget.style.color = 'rgba(255,90,90,0.65)'; }}
                        onMouseLeave={e => { e.currentTarget.style.color = 'rgba(200,134,26,0.3)'; }}
                      >
                        ×
                      </button>
                    </div>
                  );
                })}
              </div>
            </>
          )}

          {entries.length === 0 && (
            <p style={{
              fontSize: '0.62rem',
              color: 'rgba(244,228,193,0.22)',
              fontFamily: "'Lora', serif",
              fontStyle: 'italic',
              margin: '0.1rem 0.2rem 0',
            }}>
              No bookmarks yet
            </p>
          )}
        </div>
      )}
    </div>
  );
}
