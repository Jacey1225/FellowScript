// Task 20261012-share-verses-notes-in-chat (web/desktop). Client for the shared
// verse / shared note chat messages. Backend contract: api/routes/shared_objects.py
// and api/backend/interactions/shared_objects.py. The server builds the stored
// payload from our minimal input, so we only ever send a verse reference or a
// note id. Throw-not-fabricate: a failed note open resolves to null.
import { API } from '../config.js';

export const SHARED_FEATURE = 'chat_shared_objects';
export const KIND_VERSE = 'shared_verse';
export const KIND_NOTE = 'shared_note';
export const isSharedKind = (kind) => kind === KIND_VERSE || kind === KIND_NOTE;

export const NOTE_UNAVAILABLE_TITLE = 'Note unavailable';
export const NOTE_UNAVAILABLE_BODY = 'The sender removed this note or stopped sharing it.';
export const NOTE_GONE_BANNER = 'This note is no longer shared.';

// Attachment passed to useMessaging's sendMessage(text, attachment).
export function verseAttachment(book, chapter, verse) {
  return { kind: KIND_VERSE, meta: { book, chapter: Number(chapter), verse: Number(verse) } };
}

export function noteAttachment(noteId) {
  return { kind: KIND_NOTE, meta: { note_id: noteId } };
}

// Hide "Send in chat" on notes the server would refuse: other people's group
// notes that are not editable by the whole group. The server is the authority.
export function canShareNote(note, { owner, isOwn } = {}) {
  if (!note) return false;
  if (!owner) return true;            // personal note, always the caller's own
  return !!isOwn || note.public === true;
}

// Wire meta -> view model; tolerates the optimistic echo (reference only).
export function verseView(meta) {
  const m = meta || {};
  const ref = typeof m.reference === 'string' && m.reference
    ? m.reference
    : (m.book ? `${m.book} ${m.chapter}:${m.verse}${m.verse_end && m.verse_end !== m.verse ? `-${m.verse_end}` : ''}` : 'Verse');
  return {
    book: m.book || null,
    chapter: Number(m.chapter) || null,
    verse: Number(m.verse) || null,
    reference: ref,
    translation: typeof m.translation === 'string' ? m.translation : '',
    text: typeof m.text === 'string' ? m.text : '',
  };
}

export function noteView(meta) {
  const m = meta || {};
  return {
    noteId: m.note_id || null,
    title: typeof m.title === 'string' && m.title ? m.title : 'Untitled note',
    preview: typeof m.preview === 'string' ? m.preview : '',
    timestamp: typeof m.timestamp === 'string' ? m.timestamp : '',
    isGroupNote: m.is_group_note === true,
    ownerUsername: typeof m.owner_username === 'string' ? m.owner_username : '',
  };
}

// Badge copy from the design: "From <name> - Group" for group notes, otherwise
// "Shared note" (lock).
export function noteBadge(view, mine) {
  if (view.isGroupNote) return { text: mine ? 'Group note' : `From ${view.ownerUsername || 'member'} · Group`, lock: false };
  return { text: 'Shared note', lock: true };
}

// GET the read-only note for a message. Resolves { note } or { gone: true }
// (every denial is one uniform 404) or throws on transport/5xx errors.
export async function fetchSharedNote(userId, messageId) {
  const res = await fetch(
    `${API}/shared-objects/${encodeURIComponent(userId)}/note/${encodeURIComponent(messageId)}`,
    { credentials: 'include' },
  );
  if (res.status === 404) return { gone: true };
  if (!res.ok) throw new Error('shared note unavailable');
  const body = await res.json();
  if (!body || typeof body !== 'object' || body.read_only !== true) throw new Error('bad shared note');
  return { note: body };
}

// Short label for message lists/previews.
export function sharedPreviewLabel(kind, meta) {
  if (kind === KIND_VERSE) return `Verse: ${verseView(meta).reference}`;
  if (kind === KIND_NOTE) return `Note: ${noteView(meta).title}`;
  return null;
}
