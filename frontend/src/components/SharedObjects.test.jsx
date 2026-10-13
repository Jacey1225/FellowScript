// Testing gate (web half), task 20261012-share-verses-notes-in-chat, step 7.
// Covers lib/sharedObjects.js (request shape, view models, share rule, fetch
// contract), the verse widget and note card renderings, the read-only note modal
// (loading / ok / gone / error, no edit or reshare), the in-chat dispatch in
// ChatThread (fallback caption suppressed, tap behavior, pending cards not
// openable, other kinds unaffected), the Send-in-chat recipient picker, and the
// entry points on the highlight popup, note card, and note detail.
//
// Run: cd frontend && NODE_OPTIONS=--no-experimental-webstorage npx vitest run src/components/SharedObjects.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup, within } from '@testing-library/react';
import {
  verseAttachment, noteAttachment, canShareNote, verseView, noteView, noteBadge,
  fetchSharedNote, sharedPreviewLabel, isSharedKind, SHARED_FEATURE, KIND_VERSE, KIND_NOTE,
} from '../lib/sharedObjects.js';
import { SharedVerseWidget, SharedNoteCard, SharedNoteModal, sharedAriaLabel } from './SharedObjects.jsx';
import ShareToChatModal from './ShareToChatModal.jsx';
import HighlightPicker from './HighlightPicker.jsx';
import NoteCard from './panels/notes/NoteCard.jsx';
import NoteDetail from './panels/notes/NoteDetail.jsx';
import ChatThread from './ChatThread.jsx';

vi.mock('./GroupInfoPanel.jsx', () => ({ default: () => null }));

afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

// ── lib ──────────────────────────────────────────────────────────────────────
describe('lib/sharedObjects', () => {
  test('feature flag name and kinds match the server contract', () => {
    expect(SHARED_FEATURE).toBe('chat_shared_objects');
    expect(KIND_VERSE).toBe('shared_verse');
    expect(KIND_NOTE).toBe('shared_note');
    expect(isSharedKind('shared_verse')).toBe(true);
    expect(isSharedKind('shared_note')).toBe(true);
    for (const k of ['image', 'video', 'gif', 'file', null, undefined, 'shared_other']) expect(isSharedKind(k)).toBe(false);
  });

  test('attachments carry only the reference or the note id', () => {
    expect(verseAttachment('John', '3', '16')).toEqual({ kind: 'shared_verse', meta: { book: 'John', chapter: 3, verse: 16 } });
    expect(noteAttachment('n1')).toEqual({ kind: 'shared_note', meta: { note_id: 'n1' } });
    expect(Object.keys(noteAttachment('n1').meta)).toEqual(['note_id']);
  });

  test('canShareNote mirrors the server rule', () => {
    expect(canShareNote(null)).toBe(false);
    expect(canShareNote({ public: false }, {})).toBe(true);                         // personal note
    expect(canShareNote({ public: false }, { owner: 'ann', isOwn: true })).toBe(true);   // own group note
    expect(canShareNote({ public: true }, { owner: 'ann', isOwn: false })).toBe(true);   // editable by whole group
    expect(canShareNote({ public: false }, { owner: 'ann', isOwn: false })).toBe(false); // someone else's private group note
    expect(canShareNote({}, { owner: 'ann', isOwn: false })).toBe(false);
  });

  test('verseView builds a reference when the optimistic echo lacks one, and tolerates null', () => {
    expect(verseView({ book: 'John', chapter: 3, verse: 16 }).reference).toBe('John 3:16');
    expect(verseView({ book: 'John', chapter: 3, verse: 16, verse_end: 18 }).reference).toBe('John 3:16-18');
    expect(verseView({ book: 'John', chapter: 3, verse: 16, verse_end: 16 }).reference).toBe('John 3:16');
    expect(verseView({ reference: 'John 3:16', translation: 'WEB', text: 'x' })).toMatchObject({ reference: 'John 3:16', translation: 'WEB', text: 'x' });
    expect(verseView(null).reference).toBe('Verse');
    expect(verseView(undefined).text).toBe('');
  });

  test('noteView defaults and badge copy', () => {
    expect(noteView(null).title).toBe('Untitled note');
    expect(noteView({ title: '' }).title).toBe('Untitled note');
    expect(noteBadge(noteView({ is_group_note: false }), false)).toEqual({ text: 'Shared note', lock: true });
    expect(noteBadge(noteView({ is_group_note: true, owner_username: 'ann' }), false)).toEqual({ text: 'From ann · Group', lock: false });
    expect(noteBadge(noteView({ is_group_note: true, owner_username: 'ann' }), true).text).toBe('Group note');
    expect(noteBadge(noteView({ is_group_note: true }), false).text).toBe('From member · Group');
  });

  test('sharedPreviewLabel', () => {
    expect(sharedPreviewLabel(KIND_VERSE, { reference: 'John 3:16' })).toBe('Verse: John 3:16');
    expect(sharedPreviewLabel(KIND_NOTE, { title: 'Study' })).toBe('Note: Study');
    expect(sharedPreviewLabel('image', {})).toBeNull();
  });

  describe('fetchSharedNote', () => {
    test('200 with read_only resolves the note, and URL-encodes ids', async () => {
      const fetchMock = vi.fn(async () => ({ ok: true, status: 200, json: async () => ({ note_id: 'n1', title: 'T', read_only: true }) }));
      vi.stubGlobal('fetch', fetchMock);
      const r = await fetchSharedNote('u 1', 'm/1');
      expect(r.note.title).toBe('T');
      expect(fetchMock.mock.calls[0][0]).toMatch(/\/shared-objects\/u%201\/note\/m%2F1$/);
      expect(fetchMock.mock.calls[0][1]).toMatchObject({ credentials: 'include' });
    });
    test('404 is the uniform gone result', async () => {
      vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 404, json: async () => ({}) })));
      expect(await fetchSharedNote('u', 'm')).toEqual({ gone: true });
    });
    test('5xx and a payload without read_only:true throw (never fabricate)', async () => {
      vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 500, json: async () => ({}) })));
      await expect(fetchSharedNote('u', 'm')).rejects.toThrow();
      vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true, status: 200, json: async () => ({ note_id: 'n', read_only: false }) })));
      await expect(fetchSharedNote('u', 'm')).rejects.toThrow();
      vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true, status: 200, json: async () => null })));
      await expect(fetchSharedNote('u', 'm')).rejects.toThrow();
    });
  });
});

// ── components ───────────────────────────────────────────────────────────────
const verseMsg = (extra = {}) => ({
  id: 'v1', key: 'v1', mine: false, sender: 'ann', timestamp: '2026-10-12T10:00:00Z',
  text: '"For God so loved the world" — John 3:16', attachmentKind: 'shared_verse',
  attachmentMeta: { book: 'John', chapter: 3, verse: 16, reference: 'John 3:16', translation: 'WEB', text: 'For God so loved the world' }, ...extra,
});
const noteMsg = (extra = {}) => ({
  id: 'n1', key: 'n1', mine: false, sender: 'ann', timestamp: '2026-10-12T10:00:00Z',
  text: 'Shared a note: Psalm study', attachmentKind: 'shared_note',
  attachmentMeta: { note_id: 'note-1', title: 'Psalm study', preview: '<p>Notes on <b>23</b></p>', timestamp: '2026-10-11T09:00:00Z', is_group_note: false, owner_username: 'ann' }, ...extra,
});

describe('SharedVerseWidget', () => {
  test('shows reference, translation, and verse text; tap opens the reader at the verse', () => {
    const nav = vi.fn();
    render(<SharedVerseWidget message={verseMsg()} onNavigateVerse={nav} />);
    expect(screen.getByText('John 3:16 · WEB')).toBeTruthy();
    expect(screen.getByText('For God so loved the world')).toBeTruthy();
    expect(screen.getByText('Tap to read')).toBeTruthy();
    const btn = screen.getByRole('button', { name: /Verse John 3:16, shared by ann/ });
    fireEvent.click(btn);
    expect(nav).toHaveBeenCalledWith('John', 3, 16);
  });
  test('sent by you is labelled as such; without a handler it is not a button', () => {
    render(<SharedVerseWidget message={verseMsg({ mine: true })} />);
    expect(screen.queryByRole('button')).toBeNull();
    expect(screen.getByLabelText(/shared by you/)).toBeTruthy();
    expect(screen.queryByText('Tap to read')).toBeNull();
  });
  test('missing meta renders without crashing and is not tappable', () => {
    const nav = vi.fn();
    render(<SharedVerseWidget message={verseMsg({ attachmentMeta: null })} onNavigateVerse={nav} />);
    expect(screen.queryByRole('button')).toBeNull();
    expect(screen.getByText('Verse')).toBeTruthy();
  });
});

describe('SharedNoteCard', () => {
  test('title, tag-stripped preview, lock badge for a personal note; tap hands back the message', () => {
    const onOpen = vi.fn();
    const m = noteMsg();
    const { container } = render(<SharedNoteCard message={m} onOpen={onOpen} />);
    expect(screen.getByText('Psalm study')).toBeTruthy();
    expect(screen.getByText('Notes on 23')).toBeTruthy();
    expect(screen.getByText('Shared note')).toBeTruthy();
    expect(container.querySelector('.anticon-lock')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /Note Psalm study, shared by ann, opens read only/ }));
    expect(onOpen).toHaveBeenCalledWith(m);
  });
  test('group note badge names the owner and has no lock', () => {
    const { container } = render(<SharedNoteCard message={noteMsg({ attachmentMeta: { ...noteMsg().attachmentMeta, is_group_note: true } })} onOpen={vi.fn()} />);
    expect(screen.getByText('From ann · Group')).toBeTruthy();
    expect(container.querySelector('.anticon-lock')).toBeNull();
  });
  test('pending, failed, and id-less messages are not openable', () => {
    for (const extra of [{ pending: true }, { failed: true }, { id: undefined }]) {
      cleanup();
      const onOpen = vi.fn();
      render(<SharedNoteCard message={noteMsg(extra)} onOpen={onOpen} />);
      expect(screen.queryByRole('button')).toBeNull();
    }
  });
  test('aria labels per kind; undefined for other kinds', () => {
    expect(sharedAriaLabel(verseMsg())).toBe('ann: verse John 3:16');
    expect(sharedAriaLabel(noteMsg())).toBe('ann: shared note Psalm study');
    expect(sharedAriaLabel({ attachmentKind: 'file' })).toBeUndefined();
  });
});

describe('SharedNoteModal (read-only)', () => {
  const mount = (message = noteMsg(), props = {}) => render(
    <SharedNoteModal message={message} userId="u1" threadLabel="Ann" onClose={vi.fn()} onNavigateVerse={vi.fn()} {...props} />,
  );
  const okNote = { note_id: 'note-1', title: 'Psalm study', text: '<p>Body text</p>', verses: [['Psalms', 23, 1]], read_only: true, replies: [] };

  test('loaded: read-only pill, banner naming sender and chat, content, no edit/delete/reshare/reply controls', async () => {
    const fetchMock = vi.fn(async () => ({ ok: true, status: 200, json: async () => okNote }));
    vi.stubGlobal('fetch', fetchMock);
    mount();
    expect(await screen.findByText('Read only')).toBeTruthy();
    expect(screen.getByText('Shared by ann in Ann. You can view but not edit.')).toBeTruthy();
    expect(screen.getByRole('heading', { name: 'Psalm study' })).toBeTruthy();
    expect(screen.getByText('Body text')).toBeTruthy();
    expect(screen.getByRole('dialog', { name: /Psalm study, read only/ })).toBeTruthy();
    expect(fetchMock.mock.calls[0][0]).toMatch(/\/shared-objects\/u1\/note\/n1$/);
    for (const re of [/edit/i, /delete/i, /send in chat/i, /reply/i]) expect(screen.queryByRole('button', { name: re })).toBeNull();
    expect(screen.queryByRole('textbox')).toBeNull();
  });

  test('404 shows the uniform unavailable state with no content', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 404, json: async () => ({}) })));
    mount();
    expect(await screen.findByText('Note unavailable')).toBeTruthy();
    expect(screen.getByText('This note is no longer shared.')).toBeTruthy();
    expect(screen.queryByText('Read only')).toBeNull();
    expect(screen.queryByText('Body text')).toBeNull();
  });

  test('transport error shows a retryable alert, not the unavailable state', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('offline'); }));
    mount();
    expect(await screen.findByRole('alert')).toBeTruthy();
    expect(screen.queryByText('Read only')).toBeNull();
  });

  test('Back button and Escape both close', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true, status: 200, json: async () => okNote })));
    const onClose = vi.fn();
    mount(noteMsg(), { onClose });
    await screen.findByText('Read only');
    fireEvent.click(screen.getByRole('button', { name: /Back/ }));
    expect(onClose).toHaveBeenCalledTimes(1);
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(onClose).toHaveBeenCalledTimes(2);
  });

  test('a note the sender removed after the card was shown is not rendered from the card snapshot', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, status: 404, json: async () => ({}) })));
    mount();
    await screen.findByText('Note unavailable');
    expect(screen.queryByText('Notes on 23')).toBeNull();
  });
});

describe('ShareToChatModal', () => {
  const friends = [{ id: 'f1', name: 'Ann', type: 'friend' }];
  const groups = { g1: { title: 'Study Group', users: ['a', 'b'] } };
  const mount = (props = {}) => render(
    <ShareToChatModal open onClose={vi.fn()} preview={<div>PREVIEW</div>} friends={friends} groups={groups} loaded onSend={vi.fn()} {...props} />,
  );

  test('lists friends and groups with the preview; Send disabled until a chat is chosen', () => {
    mount();
    expect(screen.getByText('PREVIEW')).toBeTruthy();
    const send = screen.getByRole('button', { name: 'Send' });
    expect(send.disabled).toBe(true);
    expect(screen.getByRole('radio', { name: /Ann, friend/ })).toBeTruthy();
    expect(screen.getByRole('radio', { name: /Study Group, group/ })).toBeTruthy();
  });

  test('choosing a group then Send calls onSend with that group contact', async () => {
    const onSend = vi.fn(async () => {});
    mount({ onSend });
    fireEvent.click(screen.getByRole('radio', { name: /Study Group, group/ }));
    expect(screen.getByRole('radio', { name: /Study Group, group. Selected/ })).toBeTruthy();
    const send = screen.getByRole('button', { name: 'Send' });
    expect(send.disabled).toBe(false);
    fireEvent.click(send);
    await waitFor(() => expect(onSend).toHaveBeenCalledTimes(1));
    expect(onSend.mock.calls[0][0]).toMatchObject({ id: 'g1', type: 'group', group_id: 'g1', name: 'Study Group' });
  });

  test('choosing a friend sends to the friend contact', async () => {
    const onSend = vi.fn(async () => {});
    mount({ onSend });
    fireEvent.click(screen.getByRole('radio', { name: /Ann, friend/ }));
    fireEvent.click(screen.getByRole('button', { name: 'Send' }));
    await waitFor(() => expect(onSend).toHaveBeenCalled());
    expect(onSend.mock.calls[0][0]).toMatchObject({ id: 'f1', type: 'friend' });
  });

  test('empty state when there are no chats; spinner while not loaded; cancel closes', () => {
    const onClose = vi.fn();
    mount({ friends: [], groups: {}, onClose });
    expect(screen.getByText('No chats yet')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(onClose).toHaveBeenCalled();
    cleanup();
    mount({ loaded: false });
    expect(screen.queryByText('No chats yet')).toBeNull();
    expect(screen.queryByRole('radio')).toBeNull();
  });
});

describe('entry points', () => {
  test('HighlightPicker shows Send in chat only when a handler is supplied', () => {
    const onShare = vi.fn();
    const { rerender } = render(<HighlightPicker visible position={{ top: 0, left: 0 }} onColor={vi.fn()} onClear={vi.fn()} />);
    expect(screen.queryByText('Send in chat')).toBeNull();
    rerender(<HighlightPicker visible position={{ top: 0, left: 0 }} onColor={vi.fn()} onClear={vi.fn()} onShare={onShare} />);
    fireEvent.click(screen.getByText('Send in chat'));
    expect(onShare).toHaveBeenCalledTimes(1);
  });

  test('NoteCard: send icon only with onShare, and it does not open the note', () => {
    const note = { title: 'T', text: 'x', timestamp: '2026-10-11T09:00:00Z', verses: [] };
    const onShare = vi.fn(); const onOpen = vi.fn();
    const { rerender } = render(<NoteCard id="n1" note={note} onEdit={vi.fn()} onDelete={vi.fn()} onOpen={onOpen} />);
    expect(screen.queryByRole('button', { name: 'Send in chat' })).toBeNull();
    rerender(<NoteCard id="n1" note={note} onEdit={vi.fn()} onDelete={vi.fn()} onOpen={onOpen} onShare={onShare} />);
    fireEvent.click(screen.getByRole('button', { name: 'Send in chat' }));
    expect(onShare).toHaveBeenCalledWith('n1');
    expect(onOpen).not.toHaveBeenCalled();
  });

  test('NoteCard: other people\'s non-editable group note can still be shared only if the handler is passed (handler gated by canShareNote upstream)', () => {
    const note = { title: 'T', text: 'x', public: false, verses: [] };
    render(<NoteCard id="n1" note={note} owner="ann" isOwn={false} onEdit={vi.fn()} onDelete={vi.fn()} onOpen={vi.fn()} />);
    expect(screen.queryByRole('button', { name: 'Send in chat' })).toBeNull();
  });

  test('NoteDetail: send icon appears only with onShare and passes the note id', () => {
    const onShare = vi.fn();
    const props = { note: { title: 'T', text: '<p>b</p>', verses: [] }, noteId: 'n9', onBack: vi.fn(), canReply: false, replies: [], onNavigateVerse: vi.fn() };
    const { rerender } = render(<NoteDetail {...props} />);
    expect(screen.queryByRole('button', { name: 'Send in chat' })).toBeNull();
    rerender(<NoteDetail {...props} onShare={onShare} />);
    fireEvent.click(screen.getByRole('button', { name: 'Send in chat' }));
    expect(onShare).toHaveBeenCalledWith('n9');
  });
});

// ── ChatThread dispatch ──────────────────────────────────────────────────────
const FRIEND = { id: 'c1', name: 'Ann', type: 'friend' };
const USER = { user_id: 'u1', username: 'me' };
function mountThread(messages, props = {}) {
  Element.prototype.scrollIntoView = vi.fn();
  window.matchMedia = vi.fn(() => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }));
  const onNavigateVerse = vi.fn();
  render(
    <ChatThread contact={FRIEND} messages={messages} groupMembers={[]} user={USER} onBack={vi.fn()} onSend={vi.fn()}
      sessions={[]} activeSessionId={null} talkingUserId={null} onJoinSession={vi.fn()} onLeaveSession={vi.fn()}
      onOpenSessionCreator={vi.fn()} onEditSession={vi.fn()} onDeleteSession={vi.fn()} onNavigateVerse={onNavigateVerse}
      videoEnabled={false} videoTiles={{}} onToggleVideo={vi.fn()} bindVideoTile={vi.fn()} {...props} />,
  );
  return { onNavigateVerse };
}

describe('ChatThread shared messages', () => {
  test('verse and note render as widget/card, and the old-client fallback caption is not shown', () => {
    mountThread([verseMsg(), noteMsg()]);
    expect(screen.getByText('John 3:16 · WEB')).toBeTruthy();
    expect(screen.getByText('Psalm study')).toBeTruthy();
    expect(screen.queryByText(/For God so loved the world" — John 3:16/)).toBeNull();
    expect(screen.queryByText('Shared a note: Psalm study')).toBeNull();
    const bubble = document.querySelector('[data-msg-id="v1"]');
    expect(bubble.className).toMatch(/msg-bubble-shared/);
  });

  test('tapping the verse navigates the reader; tapping the note opens the read-only modal via the share grant', async () => {
    const fetchMock = vi.fn(async () => ({ ok: true, status: 200, json: async () => ({ note_id: 'note-1', title: 'Psalm study', text: '<p>Body text</p>', verses: [], read_only: true }) }));
    vi.stubGlobal('fetch', fetchMock);
    const { onNavigateVerse } = mountThread([verseMsg(), noteMsg()]);
    fireEvent.click(screen.getByRole('button', { name: /Verse John 3:16/ }));
    expect(onNavigateVerse).toHaveBeenCalledWith('John', 3, 16);
    fireEvent.click(screen.getByRole('button', { name: /Note Psalm study/ }));
    expect(await screen.findByText('Read only')).toBeTruthy();
    expect(fetchMock.mock.calls[0][0]).toMatch(/\/shared-objects\/u1\/note\/n1$/);
    expect(screen.getByText(/Shared by ann in Ann/)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /Back/ }));
    await waitFor(() => expect(screen.queryByText('Read only')).toBeNull());
  });

  test('a pending optimistic note card is not tappable and does not fetch', () => {
    const fetchMock = vi.fn(); vi.stubGlobal('fetch', fetchMock);
    mountThread([noteMsg({ id: undefined, key: 'tmp1', mine: true, pending: true })]);
    expect(screen.queryByRole('button', { name: /Note Psalm study/ })).toBeNull();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test('existing kinds and plain text are unaffected', () => {
    mountThread([
      { id: 't1', key: 't1', text: 'plain hello', mine: false, sender: 'ann', timestamp: '2026-10-12T10:00:00Z' },
      { id: 'f1', key: 'f1', text: 'caption here', mine: false, sender: 'ann', timestamp: '2026-10-12T10:00:00Z', attachmentKind: 'file', attachmentMeta: { filename: 'a.pdf' }, attachmentUrl: 'https://x/a.pdf' },
    ]);
    expect(screen.getByText('plain hello')).toBeTruthy();
    expect(screen.getByText('caption here')).toBeTruthy();
    expect(document.querySelector('.shared-verse')).toBeNull();
    expect(document.querySelector('.shared-note-card')).toBeNull();
  });
});
