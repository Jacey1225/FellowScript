import React, { useState } from 'react';
import { Button, Select, Typography, Spin } from 'antd';
import { PlusOutlined, FilterOutlined, LockOutlined } from '@ant-design/icons';
import { useNotesPanel } from '../../context/ReaderPanelContexts.jsx';
import NoteEditor from './notes/NoteEditor.jsx';
import NoteCard from './notes/NoteCard.jsx';
import NoteDetail from './notes/NoteDetail.jsx';
import FilterPanel from './notes/FilterPanel.jsx';
import { validVerses } from './notes/noteFormat.js';

const { Title, Text } = Typography;

// ── Notes panel ───────────────────────────────────────────────────────────────
// Dockview panel: the "Notes" tab of the old combined NotesSidebar, extracted
// so it can be independently docked. Keeps its own copy of the group-selector
// dropdown so it never loses the ability to change which group it's viewing.
//
// Readability #10 (20260904-frontend-arch-sweep): this file used to also
// define FmtBtn/NoteEditor/NoteCard/NoteDetail/FilterPanel inline (834 loc,
// five distinct components sharing near-duplicated hover-style handlers).
// Split into ./notes/*.jsx by component, with the shared hover-handler and
// formatting helpers factored into ./notes/noteFormat.js and a single
// VerseChip component replacing NoteCard's and NoteDetail's previously
// separate, near-identical verse-reference chip implementations. No behavior
// change -- same default export, same props/contract for every child.
export default function NotesPanel() {
  const {
    user, currentGroupId, groups, onGroupChange, onNavigateVerse,
    notesData, groupLoading, filterActive,
    saveNote, deleteNote, postReply, loadDetailReplies,
    applyFilter, clearFilter,
    books, chapterCount, verseCount,
  } = useNotesPanel() || {};

  const [editorOpen,   setEditorOpen]   = useState(false);
  const [editorNoteId, setEditorNoteId] = useState(null);
  const [detailNote,   setDetailNote]   = useState(null);
  const [detailId,     setDetailId]     = useState(null);
  const [showFilter,   setShowFilter]   = useState(false);
  const [replies,      setReplies]      = useState([]);
  const [repliesLoading, setRepliesLoading] = useState(false);

  const notes = notesData || {};

  const verseList = React.useMemo(() => {
    const list = [];
    if (currentGroupId) {
      const myUsername = user?.username || '';
      // Display is group_id-only now: the backend already returns every note
      // that matches this group, so every one of them belongs in the list --
      // `public` no longer means "visible," only "group members may edit."
      const groupSrc   = notes.filteredGroup || notes.group || {};
      Object.entries(groupSrc).forEach(([uname, noteMap]) => {
        Object.entries(noteMap).forEach(([id, note]) => {
          list.push([id, note, uname, uname === myUsername]);
        });
      });
    } else {
      const src = notes.filtered || notes.all || {};
      Object.entries(src).forEach(([id, note]) => {
        list.push([id, note, null, false]);
      });
    }
    if (filterActive) return list;
    return list.sort((a, b) => {
      const ta = new Date(a[1]?.created_at || a[1]?.timestamp || 0).getTime() || 0;
      const tb = new Date(b[1]?.created_at || b[1]?.timestamp || 0).getTime() || 0;
      return tb - ta;
    });
  }, [notes, currentGroupId, user, filterActive]);

  const openEditor = (id = null) => { setEditorNoteId(id); setEditorOpen(true); };
  const closeEditor = () => { setEditorOpen(false); setEditorNoteId(null); };

  const handleEditorSave = async (body, noteId) => await saveNote(body, noteId);

  const openDetail = async (id) => {
    const note = notes.all?.[id]
      || Object.values(notes.group || {}).reduce((f, m) => f || m[id], null);
    if (!note) return;
    setDetailId(id);
    setDetailNote(note);
    if (currentGroupId) {
      setRepliesLoading(true);
      const r = await loadDetailReplies(id);
      setReplies(Array.isArray(r) ? r : []);
      setRepliesLoading(false);
    }
  };

  const closeDetail = () => { setDetailId(null); setDetailNote(null); setReplies([]); };

  const handleDelete = async (id) => {
    if (!window.confirm('Delete this note?')) return;
    await deleteNote(id);
  };

  const verseEmpty = (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', flex: 1, padding: '2.5rem 1.5rem', textAlign: 'center', gap: '1rem' }}>
      <div style={{ fontFamily: "'Inter', sans-serif", fontStyle: 'italic', fontSize: '2rem', color: 'rgba(255,198,26,0.25)', lineHeight: 1 }}>✦</div>
      <Text style={{ fontFamily: "'Space Grotesk', sans-serif", fontSize: '0.95rem', color: 'rgba(242,242,242,0.55)', display: 'block', lineHeight: 1.4 }}>
        Your study begins here
      </Text>
      <Text style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.72rem', color: 'rgba(242,242,242,0.28)', lineHeight: 1.65, display: 'block' }}>
        Tap <strong style={{ color: 'rgba(255,198,26,0.55)' }}>New</strong> to capture your first note.
      </Text>
      <Button
        size="small" icon={<PlusOutlined />}
        onClick={() => openEditor(null)}
        style={{ marginTop: '0.2rem', background: 'linear-gradient(135deg, var(--gold-light), var(--gold) 60%, var(--gold-dim))', border: 'none', color: 'var(--ink)', fontFamily: "'Space Grotesk', sans-serif", fontWeight: 600, borderRadius: 999 }}
      >
        New Note
      </Button>
    </div>
  );

  // classNames (not a bare `.ant-select`/`.ant-select-dropdown` selector) so
  // the glass restyle (item 5, 20260825-reader-dock-rail-polish) is scoped to
  // just this one Select — antd's other Selects app-wide (sort/filter here,
  // NotesSidebar's own separate mobile group selector) are untouched.
  const groupSelector = (groups || []).length > 0 ? (
    <Select
      className="notes-group-select"
      popupClassName="notes-group-select-dropdown"
      value={currentGroupId || ''}
      onChange={onGroupChange}
      size="small"
      popupMatchSelectWidth={false}
      style={{ minWidth: 80, maxWidth: 120, fontSize: '0.68rem' }}
      options={[
        { value: '', label: 'Personal' },
        ...(groups || []).map(g => ({ value: g.id, label: g.title })),
      ]}
    />
  ) : null;

  if (!user) {
    return (
      <div className="notes-sidebar" style={{ alignItems: 'center', justifyContent: 'center', gap: '1.2rem', padding: '2rem', textAlign: 'center' }}>
        <LockOutlined style={{ fontSize: 22, color: 'rgba(255,198,26,0.35)' }} />
        <Text style={{ fontSize: '0.82rem', color: 'rgba(242,242,242,0.4)', lineHeight: 1.6 }}>Sign in to take notes while you read.</Text>
        <Button href="#/signin" style={{ padding: '0.6rem 1.6rem', letterSpacing: '0.15em', textTransform: 'uppercase' }}>Sign In</Button>
      </div>
    );
  }

  if (editorOpen) {
    const editorNote = editorNoteId ? (notes.all?.[editorNoteId] || null) : null;
    return (
      <div className="notes-sidebar">
        <NoteEditor
          note={editorNote}
          noteId={editorNoteId}
          user={user}
          currentGroupId={currentGroupId}
          books={books || []}
          chapterCount={chapterCount || (() => 0)}
          verseCount={verseCount || (() => 0)}
          onSave={handleEditorSave}
          onBack={closeEditor}
        />
      </div>
    );
  }

  return (
    <div className="notes-sidebar">
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0.95rem 0.6rem 0.8rem', borderBottom: '1px solid rgba(255,255,255,0.072)', flexShrink: 0, gap: '0.5rem' }}>
        <Title level={5} style={{ margin: 0, fontFamily: "'Space Grotesk', sans-serif", fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.03em', color: 'var(--parchment)' }}>Notes</Title>
        <div style={{ display: 'flex', gap: 4, alignItems: 'center' }}>
          {/* Filter/funnel button is leftmost (20260826-notes-panel-glass-toolbar,
              item 2) -- before groupSelector and +New. Pure ordering change;
              the button's own styling/behavior is untouched. */}
          <Button
            type="text" size="small" icon={<FilterOutlined />}
            onClick={() => setShowFilter(true)}
            style={{ color: filterActive ? 'var(--gold)' : 'rgba(255,198,26,0.55)' }}
          />
          {groupSelector}
          <Button
            size="small" icon={<PlusOutlined />}
            onClick={() => openEditor(null)}
            style={{ background: 'linear-gradient(135deg, var(--gold-light), var(--gold) 60%, var(--gold-dim))', border: 'none', color: 'var(--ink)', fontFamily: "'Space Grotesk', sans-serif", fontWeight: 600, borderRadius: 999 }}
          >
            New
          </Button>
        </div>
      </div>

      {detailNote
        ? <NoteDetail
            note={detailNote} noteId={detailId}
            onBack={closeDetail}
            canReply={!!currentGroupId}
            onReply={postReply}
            replies={replies} repliesLoading={repliesLoading}
            onNavigateVerse={onNavigateVerse}
          />
        : <div style={{ flex: 1, overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: '0.7rem', padding: verseList.length ? '0.5rem 0.4rem' : 0 }}>
            {groupLoading && currentGroupId && verseList.length === 0
              ? <div style={{ display: 'flex', justifyContent: 'center', alignItems: 'center', padding: '3rem 0' }}><Spin size="default" /></div>
              : verseList.length === 0
              ? verseEmpty
              : (() => {
                  const bookGroups = new Map();
                  verseList.forEach(entry => {
                    const book = validVerses(entry[1]?.verses)[0]?.[0] || '__none__';
                    if (!bookGroups.has(book)) bookGroups.set(book, []);
                    bookGroups.get(book).push(entry);
                  });
                  const mostRecentTime = (entries) => Math.max(
                    ...entries.map(([, note]) =>
                      new Date(note?.created_at || note?.timestamp || 0).getTime() || 0
                    )
                  );
                  const sorted = [...bookGroups.entries()].sort(([a, entriesA], [b, entriesB]) => {
                    if (a === '__none__') return 1;
                    if (b === '__none__') return -1;
                    return mostRecentTime(entriesB) - mostRecentTime(entriesA);
                  });
                  return sorted.flatMap(([book, entries]) => [
                    <div key={`hdr-${book}`} style={{
                      fontFamily: "'Space Grotesk', sans-serif",
                      fontSize: '1.05rem',
                      fontWeight: 700,
                      letterSpacing: '0.02em',
                      color: 'rgba(201,138,75,0.7)',
                      padding: '0.6rem 0.5rem 0.3rem',
                      marginTop: '0.25rem',
                    }}>
                      {book === '__none__' ? 'General' : book}
                    </div>,
                    ...entries.map(([id, note, owner, isOwn]) => (
                      <div key={id} style={{ paddingLeft: '0.85rem' }}>
                        <NoteCard id={id} note={note} owner={owner} isOwn={isOwn}
                          onEdit={openEditor} onDelete={handleDelete} onOpen={openDetail}
                          onNavigateVerse={onNavigateVerse} />
                      </div>
                    )),
                  ]);
                })()
            }
          </div>
      }

      {showFilter && (
        <FilterPanel
          onApply={(params) => { applyFilter({ ...params, activeTab: 'verse' }); setShowFilter(false); }}
          onClear={() => { clearFilter(); setShowFilter(false); }}
          onClose={() => setShowFilter(false)}
          groupUsernames={Object.keys(notes.group || {})}
        />
      )}
    </div>
  );
}
