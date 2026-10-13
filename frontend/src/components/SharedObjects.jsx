// Task 20261012-share-verses-notes-in-chat (web/desktop). Chat renderings for
// the two shared kinds (approved design: verse widget variant C, note card in
// the NoteRow look) and the read-only note modal a tapped card opens.
import React, { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Spin } from 'antd';
import { LockOutlined, ArrowLeftOutlined } from '@ant-design/icons';
import { NoteBody, stripHtml } from './RichText.jsx';
import VerseChip from './panels/notes/VerseChip.jsx';
import { fmtDate, validVerses } from './panels/notes/noteFormat.js';
import {
  KIND_VERSE, KIND_NOTE, verseView, noteView, noteBadge, fetchSharedNote,
  NOTE_UNAVAILABLE_TITLE, NOTE_UNAVAILABLE_BODY, NOTE_GONE_BANNER,
} from '../lib/sharedObjects.js';

// Verse widget: grainy caramel/gold gradient (CSS .shared-verse), black text in
// the app-title font (Schibsted Grotesk SemiBold). Tap opens the reader there.
export function SharedVerseWidget({ message, onNavigateVerse }) {
  const v = verseView(message.attachmentMeta);
  const label = `Verse ${v.reference}, shared by ${message.mine ? 'you' : (message.sender || 'a friend')}`;
  const canOpen = !!(onNavigateVerse && v.book && v.chapter && v.verse);
  const Tag = canOpen ? 'button' : 'div';
  return (
    <Tag
      {...(canOpen ? { type: 'button', onClick: () => onNavigateVerse(v.book, v.chapter, v.verse) } : {})}
      className="shared-verse"
      aria-label={label}
    >
      <span className="shared-verse-ref">{v.reference}{v.translation ? ` · ${v.translation}` : ''}</span>
      {v.text && <span className="shared-verse-text">{v.text}</span>}
      <span className="shared-verse-foot">
        <span>FellowScript</span>
        {canOpen && <span>Tap to read</span>}
      </span>
    </Tag>
  );
}

// Note card: same glass look as the Notes list card, with the share badge.
export function SharedNoteCard({ message, onOpen }) {
  const v = noteView(message.attachmentMeta);
  const badge = noteBadge(v, !!message.mine);
  const canOpen = !!(onOpen && message.id && !message.pending && !message.failed);
  const label = `Note ${v.title}, shared by ${message.mine ? 'you' : (message.sender || 'a friend')}, opens read only`;
  const Tag = canOpen ? 'button' : 'div';
  return (
    <Tag
      {...(canOpen ? { type: 'button', onClick: () => onOpen(message) } : {})}
      className={`shared-note-card${message.pending ? ' shared-note-card-pending' : ''}`}
      aria-label={label}
    >
      <span className="shared-note-title">{v.title}</span>
      {v.preview && <span className="shared-note-preview">{stripHtml(v.preview)}</span>}
      <span className="shared-note-foot">
        <span className="shared-note-date">{fmtDate(v.timestamp)}</span>
        <span className="shared-note-badge">
          {badge.lock && <LockOutlined aria-hidden="true" />}
          {badge.text}
        </span>
      </span>
    </Tag>
  );
}

export function sharedAriaLabel(m) {
  if (m.attachmentKind === KIND_VERSE) return `${m.sender || 'You'}: verse ${verseView(m.attachmentMeta).reference}`;
  if (m.attachmentKind === KIND_NOTE) return `${m.sender || 'You'}: shared note ${noteView(m.attachmentMeta).title}`;
  return undefined;
}

// Read-only note page (modal). Fetches through the share grant (the message).
// States: loading, loaded, gone (revoked/deleted), error.
export function SharedNoteModal({ message, userId, threadLabel, onClose, onNavigateVerse }) {
  const [state, setState] = useState({ phase: 'loading', note: null });
  const closeRef = useRef(null);
  const card = noteView(message.attachmentMeta);

  useEffect(() => {
    let live = true;
    fetchSharedNote(userId, message.id)
      .then((r) => { if (live) setState(r.gone ? { phase: 'gone', note: null } : { phase: 'ok', note: r.note }); })
      .catch(() => { if (live) setState({ phase: 'error', note: null }); });
    return () => { live = false; };
  }, [userId, message.id]);

  useEffect(() => {
    closeRef.current?.focus();
    const onKey = (e) => { if (e.key === 'Escape') onClose(); };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onClose]);

  const note = state.note;
  const verses = validVerses(note?.verses);
  const by = message.mine ? 'you' : (message.sender || note?.shared_by || 'a friend');

  return createPortal(
    <div className="shared-note-overlay" onClick={onClose}>
      <div className="shared-note-sheet" role="dialog" aria-modal="true" aria-label={`${card.title}, read only`} onClick={(e) => e.stopPropagation()}>
        <div className="shared-note-sheet-top">
          <button ref={closeRef} type="button" className="shared-note-back" onClick={onClose}>
            <ArrowLeftOutlined aria-hidden="true" /> Back
          </button>
          {state.phase === 'ok' && <span className="shared-note-readonly">Read only</span>}
        </div>
        {state.phase === 'loading' && <div className="shared-note-center"><Spin /></div>}
        {state.phase === 'gone' && (
          <>
            <p className="shared-note-banner shared-note-banner-muted">{NOTE_GONE_BANNER}</p>
            <div className="shared-note-unavailable">
              <strong>{NOTE_UNAVAILABLE_TITLE}</strong>
              <span>{NOTE_UNAVAILABLE_BODY}</span>
            </div>
          </>
        )}
        {state.phase === 'error' && (
          <p className="shared-note-banner shared-note-banner-muted" role="alert">Couldn&apos;t open this note. Check your connection and try again.</p>
        )}
        {state.phase === 'ok' && (
          <>
            <p className="shared-note-banner">
              Shared by {by}{threadLabel ? ` in ${threadLabel}` : ''}. You can view but not edit.
            </p>
            <div className="shared-note-body">
              <h2 className="shared-note-h">{note.title || 'Untitled note'}</h2>
              {verses.length > 0 && (
                <div className="shared-note-chips">
                  {verses.map((v, i) => (
                    <VerseChip key={i} verse={v} bordered
                      onNavigateVerse={onNavigateVerse ? (...a) => { onClose(); onNavigateVerse(...a); } : undefined} />
                  ))}
                </div>
              )}
              <NoteBody html={note.text} />
            </div>
          </>
        )}
      </div>
    </div>,
    document.body,
  );
}

export { KIND_VERSE, KIND_NOTE };
