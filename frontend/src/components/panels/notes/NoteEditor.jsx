import React, { useState, useEffect, useRef } from 'react';
import { Switch } from 'antd';
import { sanitizeNoteHtml } from '../../RichText.jsx';
import VerseSelector from '../../VerseSelector.jsx';
import FmtBtn from './FmtBtn.jsx';
import { TEXT_COLORS, hoverStyleHandlers } from './noteFormat.js';

// ── Note editor (Apple Notes style) ──────────────────────────────────────────
export default function NoteEditor({ note, noteId, user, currentGroupId, books, chapterCount, verseCount, onSave, onBack }) {
  const [titleVal,   setTitleVal]   = useState(note?.title || '');
  const [isPublic,   setIsPublic]   = useState(noteId ? (note?.public || false) : false);
  const [verseList,  setVerseList]  = useState(() => {
    if (!note?.verses) return [];
    return note.verses
      .filter(v => Array.isArray(v) && v.length >= 3 && v[0])
      .map(([b, c, v]) => ({ book: b, chapter: c, verse: v }));
  });
  const [showColors,    setShowColors]    = useState(false);
  const [activeFormats, setActiveFormats] = useState({ bold: false, italic: false, underline: false, highlight: false, color: false });

  const titleRef     = useRef(null);
  const bodyRef      = useRef(null);
  const colorWrapRef = useRef(null);

  // Sanitized through sanitizeNoteHtml() — note.text can contain
  // attacker-influenceable HTML (e.g. group-shared notes, AI-summarized
  // content), so it must never be assigned to innerHTML raw.
  useEffect(() => {
    if (bodyRef.current) bodyRef.current.innerHTML = sanitizeNoteHtml(note?.text || '');
  }, []);

  useEffect(() => {
    if (titleRef.current) {
      titleRef.current.style.height = 'auto';
      titleRef.current.style.height = titleRef.current.scrollHeight + 'px';
    }
  }, [titleVal]);

  useEffect(() => { titleRef.current?.focus(); }, []);

  useEffect(() => {
    const qcs = (cmd) => { try { return document.queryCommandState(cmd); } catch { return false; } };

    const onSel = () => {
      if (!bodyRef.current) return;
      const sel = window.getSelection();
      if (!sel || !sel.rangeCount || !bodyRef.current.contains(sel.anchorNode)) {
        setActiveFormats({ bold: false, italic: false, underline: false, highlight: false, color: false });
        return;
      }
      let el = sel.anchorNode?.nodeType === Node.TEXT_NODE
        ? sel.anchorNode.parentElement
        : sel.anchorNode;
      let inMark = false;
      let hasColor = false;
      while (el && el !== bodyRef.current) {
        if (el.tagName === 'MARK')                                  inMark    = true;
        if (!hasColor && el.style?.color)                           hasColor  = true;
        if (!hasColor && el.tagName === 'FONT' && el.getAttribute('color')) hasColor = true;
        el = el.parentElement;
      }
      setActiveFormats({
        bold:      qcs('bold'),
        italic:    qcs('italic'),
        underline: qcs('underline'),
        highlight: inMark,
        color:     hasColor,
      });
    };

    document.addEventListener('selectionchange', onSel);
    return () => document.removeEventListener('selectionchange', onSel);
  }, []);

  useEffect(() => {
    if (!showColors) return;
    const close = (e) => { if (!colorWrapRef.current?.contains(e.target)) setShowColors(false); };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, [showColors]);

  const addVerse    = (book, chapter, verse) => setVerseList(p => [...p, { book, chapter, verse }]);
  const removeVerse = (i) => setVerseList(p => p.filter((_, j) => j !== i));

  const handleSave = async () => {
    const ok = await onSave({
      user:     user.user_id,
      // Group attachment is now its own decision, independent of the
      // edit-permission toggle below: a note opened in a group context
      // always gets tagged into that group. `public` no longer has any say
      // in *whether* the note is shared -- only in whether other group
      // members may edit it once it's there.
      group_id: currentGroupId || '',
      replies:  note?.replies || [],
      title:    titleVal.trim() || 'Untitled',
      text:     bodyRef.current?.innerHTML || '',
      public:   isPublic,
      verses:   verseList.map(v => [v.book, v.chapter, v.verse]),
    }, noteId || null);
    if (ok) onBack();
  };

  const fmt = (cmd, val = null) => (e) => {
    e.preventDefault();
    bodyRef.current?.focus();
    document.execCommand(cmd, false, val);
  };

  const toggleHighlight = (e) => {
    e.preventDefault();
    bodyRef.current?.focus();
    const sel = window.getSelection();
    if (!sel || !sel.rangeCount) return;

    let node = sel.anchorNode;
    let el   = node?.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    let markEl = null;
    while (el && el !== bodyRef.current) {
      if (el.tagName === 'MARK') { markEl = el; break; }
      el = el.parentElement;
    }

    if (markEl) {
      const parent = markEl.parentNode;
      while (markEl.firstChild) parent.insertBefore(markEl.firstChild, markEl);
      parent.removeChild(markEl);
    } else {
      if (sel.isCollapsed) return;
      const range = sel.getRangeAt(0);
      const mark  = document.createElement('mark');
      try {
        range.surroundContents(mark);
      } catch {
        mark.appendChild(range.extractContents());
        range.insertNode(mark);
      }
      sel.removeAllRanges();
    }
  };

  const applyColor = (color) => (e) => {
    e.preventDefault();
    setShowColors(false);
    bodyRef.current?.focus();
    document.execCommand('foreColor', false, color);
  };

  const onColorBtnMouseDown = (e) => {
    e.preventDefault();
    bodyRef.current?.focus();
    const sel = window.getSelection();
    if (sel && sel.rangeCount) {
      let node = sel.anchorNode;
      let el   = node?.nodeType === Node.TEXT_NODE ? node.parentElement : node;
      while (el && el !== bodyRef.current) {
        if (el.style?.color) {
          el.style.removeProperty('color');
          if (!el.getAttribute('style')) el.removeAttribute('style');
          setShowColors(false);
          return;
        }
        if (el.tagName === 'FONT' && el.getAttribute('color')) {
          el.removeAttribute('color');
          setShowColors(false);
          return;
        }
        el = el.parentElement;
      }
    }
    setShowColors(v => !v);
  };

  const colorSwatchHover = hoverStyleHandlers(
    { transform: 'scale(1.3)', boxShadow: '0 0 0 2px rgba(255,255,255,0.15)' },
    { transform: 'scale(1)', boxShadow: 'none' }
  );

  return (
    <div className="note-editor">
      <div className="note-editor-header">
        <button className="note-editor-action-btn note-editor-cancel" onClick={onBack}>Cancel</button>
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.45rem', flex: 1, justifyContent: 'center' }}>
          {/* Edit-permission toggle only means anything once the note has a
              group -- a personal note (no currentGroupId) has no one else
              who could edit it, so the control is hidden rather than shown
              disabled. */}
          {currentGroupId && (
            <>
              <Switch size="small" checked={isPublic} onChange={setIsPublic}
                style={{ background: isPublic ? 'rgba(255,198,26,0.8)' : undefined }} />
              <span style={{ fontSize: '0.72rem', color: 'rgba(242,242,242,0.55)', fontFamily: "'Inter', sans-serif" }}>Allow group to edit</span>
            </>
          )}
        </div>
        <button className="note-editor-action-btn note-editor-save" onClick={handleSave}>Save</button>
      </div>

      <div className="note-editor-verse-bar">
        {verseList.map((v, i) => (
          <span key={i} className="note-verse-tag">
            <em>{v.book} {v.chapter}:{v.verse}</em>
            <button className="note-verse-remove" onClick={() => removeVerse(i)}>×</button>
          </span>
        ))}
        {books?.length > 0 && (
          <VerseSelector books={books} chapterCount={chapterCount} verseCount={verseCount} onSelect={addVerse} />
        )}
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: '0.45rem', padding: '0.55rem 0.85rem 0.5rem', flexWrap: 'wrap', borderBottom: '1px solid rgba(255,255,255,0.072)' }}>
        <FmtBtn title="Bold (click again to remove)" onMouseDown={fmt('bold')} active={activeFormats.bold}>
          <strong style={{ fontFamily: "'Inter', sans-serif", fontSize: '1rem', letterSpacing: '0.01em' }}>B</strong>
        </FmtBtn>
        <FmtBtn title="Italic (click again to remove)" onMouseDown={fmt('italic')} active={activeFormats.italic}>
          <em style={{ fontFamily: "'Inter', sans-serif", fontSize: '1rem' }}>I</em>
        </FmtBtn>
        <FmtBtn title="Underline (click again to remove)" onMouseDown={fmt('underline')} active={activeFormats.underline}>
          <span style={{ textDecoration: 'underline', textUnderlineOffset: 3, fontFamily: "'Inter', sans-serif", fontSize: '1rem' }}>U</span>
        </FmtBtn>
        <FmtBtn title="Highlight (click again to remove)" onMouseDown={toggleHighlight} active={activeFormats.highlight}>
          <span style={{ background: activeFormats.highlight ? 'rgba(255,198,26,0.65)' : 'rgba(255,198,26,0.42)', borderRadius: 3, padding: '1px 5px', fontFamily: "'Inter', sans-serif", fontSize: '0.9rem' }}>H</span>
        </FmtBtn>
        <div ref={colorWrapRef} style={{ position: 'relative' }}>
          <FmtBtn title={activeFormats.color ? 'Remove color' : 'Text color'} onMouseDown={onColorBtnMouseDown} active={activeFormats.color}>
            <span style={{ borderBottom: `2.5px solid ${activeFormats.color ? 'var(--gold)' : 'var(--gold)'}`, paddingBottom: 2, fontFamily: "'Inter', sans-serif", fontSize: '1rem' }}>A</span>
          </FmtBtn>
          {showColors && (
            <div style={{
              position: 'absolute', top: 'calc(100% + 8px)', left: 0,
              display: 'flex', gap: '0.38rem',
              background: 'rgba(12,7,1,0.97)',
              border: 'none',
              borderRadius: 14,
              padding: '0.5rem 0.6rem',
              zIndex: 30,
            }}>
              {TEXT_COLORS.map(color => (
                <button
                  key={color}
                  onMouseDown={applyColor(color)}
                  title={color}
                  style={{
                    width: 24, height: 24,
                    borderRadius: '50%',
                    background: color,
                    border: 'none',
                    cursor: 'pointer',
                    padding: 0,
                    flexShrink: 0,
                    transition: 'transform 0.12s, box-shadow 0.12s',
                  }}
                  {...colorSwatchHover}
                />
              ))}
            </div>
          )}
        </div>
      </div>

      <div className="note-editor-body">
        <textarea
          ref={titleRef}
          className="note-title-input"
          placeholder="Title"
          value={titleVal}
          onChange={e => setTitleVal(e.target.value)}
        />
        <div
          ref={bodyRef}
          contentEditable
          suppressContentEditableWarning
          className="note-body-textarea"
          data-placeholder="Start writing…"
        />
      </div>
    </div>
  );
}
