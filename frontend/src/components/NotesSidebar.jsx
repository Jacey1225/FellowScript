import React, { useState, useCallback, useEffect, useRef } from 'react';
import {
  Button, Tabs, Input, Select, Typography,
  Spin, Divider, Tag, Switch,
} from 'antd';
import {
  PlusOutlined, EditOutlined, DeleteOutlined, FilterOutlined,
  ArrowLeftOutlined, ReloadOutlined,
} from '@ant-design/icons';
// Format a single [book, chapter, verse] triple into a display string
function fmtVerse([b, c, v]) { return `${b} ${c}:${v}`; }

// Return an array of valid verse triples from a note's verses field.
// Handles both the old [start, end] range format and the new per-verse list.
function validVerses(verses) {
  if (!Array.isArray(verses)) return [];
  return verses.filter(v => Array.isArray(v) && v.length >= 3 && v[0]);
}
import VerseSelector from './VerseSelector.jsx';

const { TextArea } = Input;
const { Text, Title } = Typography;

// ── Note editor (Apple Notes style) ──────────────────────────────────────────

function NoteEditor({ note, noteId, user, currentGroupId, books, chapterCount, verseCount, onSave, onBack }) {
  const [titleVal,  setTitleVal]  = useState(note?.title || '');
  const [bodyVal,   setBodyVal]   = useState(note?.text  || '');
  const [isPublic,  setIsPublic]  = useState(!noteId ? true : (note?.public || false));
  const [verseList, setVerseList] = useState(() => {
    if (!note?.verses) return [];
    return note.verses
      .filter(v => Array.isArray(v) && v.length >= 3 && v[0])
      .map(([b, c, v]) => ({ book: b, chapter: c, verse: v }));
  });
  const titleRef = useRef(null);

  // Auto-resize title textarea
  useEffect(() => {
    if (titleRef.current) {
      titleRef.current.style.height = 'auto';
      titleRef.current.style.height = titleRef.current.scrollHeight + 'px';
    }
  }, [titleVal]);

  useEffect(() => { titleRef.current?.focus(); }, []);

  const addVerse    = (book, chapter, verse) => setVerseList(p => [...p, { book, chapter, verse }]);
  const removeVerse = (i) => setVerseList(p => p.filter((_, j) => j !== i));

  const handleSave = async () => {
    await onSave({
      user:     user.user_id,
      group_id: isPublic && currentGroupId ? currentGroupId : '',
      replies:  note?.replies || [],
      title:    titleVal.trim() || 'Untitled',
      text:     bodyVal.trim(),
      public:   isPublic,
      verses:   verseList.map(v => [v.book, v.chapter, v.verse]),
    }, noteId || null);
    onBack();
  };

  return (
    <div className="note-editor">
      {/* Header — Cancel left, Save right, always visible above keyboard */}
      <div className="note-editor-header">
        <button className="note-editor-action-btn note-editor-cancel" onClick={onBack}>
          Cancel
        </button>
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.45rem', flex: 1, justifyContent: 'center' }}>
          <Switch
            size="small"
            checked={isPublic}
            onChange={setIsPublic}
            style={{ background: isPublic ? 'rgba(200,134,26,0.8)' : undefined }}
          />
          <span style={{ fontSize: '0.72rem', color: 'rgba(244,228,193,0.55)', fontFamily: "'Lora', serif" }}>Public</span>
        </div>
        <button className="note-editor-action-btn note-editor-save" onClick={handleSave}>
          Save
        </button>
      </div>

      {/* Verse bar */}
      <div className="note-editor-verse-bar">
        {verseList.map((v, i) => (
          <span key={i} className="note-verse-tag">
            <em>{v.book} {v.chapter}:{v.verse}</em>
            <button className="note-verse-remove" onClick={() => removeVerse(i)}>×</button>
          </span>
        ))}
        {books?.length > 0 && (
          <VerseSelector
            books={books}
            chapterCount={chapterCount}
            verseCount={verseCount}
            onSelect={addVerse}
          />
        )}
      </div>

      {/* Writing area */}
      <div className="note-editor-body">
        <textarea
          ref={titleRef}
          className="note-title-input"
          placeholder="Title"
          value={titleVal}
          onChange={e => setTitleVal(e.target.value)}
        />
        <textarea
          className="note-body-textarea"
          placeholder="Start writing…"
          value={bodyVal}
          onChange={e => setBodyVal(e.target.value)}
        />
      </div>
    </div>
  );
}

// ── Note card ─────────────────────────────────────────────────────────────────

function NoteCard({ id, note, owner, isOwn, onEdit, onDelete, onOpen, onNavigateVerse }) {
  const verses  = validVerses(note.verses);
  const canEdit = !owner || isOwn;

  return (
    <div
      className="note-card ant-card"
      style={{ border: '1px solid rgba(200,134,26,0.18)', background: 'rgba(20,12,4,0.5)', padding: '0.6rem 0.65rem', borderRadius: 10, cursor: 'pointer', marginBottom: 0, transition: 'border-color 0.2s' }}
      onClick={() => onOpen(id)}
    >
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: '0.5rem', marginBottom: '0.4rem' }}>
        <Text strong style={{ fontFamily: "'Lora', serif", fontSize: '0.85rem', color: 'var(--parchment)', lineHeight: 1.3 }}>
          {note.title || 'Untitled'}
          {note.public && <Tag style={{ marginLeft: 6, fontSize: '0.52rem', letterSpacing: '0.12em' }}>Public</Tag>}
          {owner && <Tag color="gold" style={{ marginLeft: 4, fontSize: '0.52rem' }}>{owner}</Tag>}
        </Text>
        {canEdit && (
          <div style={{ display: 'flex', gap: 2, flexShrink: 0 }} onClick={e => e.stopPropagation()}>
            <Button type="text" size="small" icon={<EditOutlined />} onClick={() => onEdit(id)}
              style={{ color: 'rgba(200,134,26,0.45)', padding: '0 4px' }} />
            <Button type="text" size="small" icon={<DeleteOutlined />} onClick={() => onDelete(id)}
              style={{ color: 'rgba(200,134,26,0.45)', padding: '0 4px' }} />
          </div>
        )}
      </div>
      {verses.length > 0 && (
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.3rem', marginBottom: '0.45rem' }} onClick={e => e.stopPropagation()}>
          {verses.map((v, i) => (
            <button
              key={i}
              onClick={() => { if (onNavigateVerse) onNavigateVerse(v[0], v[1], v[2]); }}
              style={{
                background: 'rgba(200,134,26,0.1)',
                border: '1px solid rgba(200,134,26,0.28)',
                borderRadius: 4,
                padding: '0.1rem 0.5rem',
                cursor: onNavigateVerse ? 'pointer' : 'default',
                fontFamily: "'IM Fell English', serif",
                fontStyle: 'italic',
                fontSize: '0.68rem',
                color: 'var(--gold)',
                transition: 'background 0.15s, border-color 0.15s',
              }}
              onMouseEnter={e => { if (onNavigateVerse) { e.currentTarget.style.background = 'rgba(200,134,26,0.2)'; e.currentTarget.style.borderColor = 'rgba(200,134,26,0.55)'; } }}
              onMouseLeave={e => { e.currentTarget.style.background = 'rgba(200,134,26,0.1)'; e.currentTarget.style.borderColor = 'rgba(200,134,26,0.28)'; }}
            >
              {fmtVerse(v)}
            </button>
          ))}
        </div>
      )}
      <p style={{ margin: 0, fontSize: '0.8rem', color: 'rgba(244,228,193,0.55)', lineHeight: 1.6, display: '-webkit-box', WebkitLineClamp: 3, WebkitBoxOrient: 'vertical', overflow: 'hidden', maxHeight: '3.84rem' }}>
        {note.text}
      </p>
    </div>
  );
}

// ── Note detail ───────────────────────────────────────────────────────────────

function NoteDetail({ note, noteId, onBack, canReply, onReply, replies, repliesLoading, onNavigateVerse }) {
  const [replyText, setReplyText] = useState('');
  const [replying,  setReplying]  = useState(false);
  const verses = validVerses(note?.verses);

  const handleReply = async () => {
    if (!replyText.trim()) return;
    setReplying(true);
    await onReply(noteId, replyText);
    setReplyText('');
    setReplying(false);
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', flex: 1, overflow: 'hidden' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.65rem', padding: '0.55rem 0.6rem', borderBottom: '1px solid rgba(200,134,26,0.15)', flexShrink: 0 }}>
        <Button type="text" icon={<ArrowLeftOutlined />} onClick={onBack} style={{ color: 'rgba(200,134,26,0.6)', padding: '0 4px' }} />
        <Text strong style={{ fontFamily: "'Playfair Display', serif", fontSize: '0.95rem', color: 'var(--parchment)', flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {note?.title || 'Note'}
        </Text>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '0.85rem 0.6rem', display: 'flex', flexDirection: 'column', gap: '0.75rem' }}>
        <Text style={{ fontSize: '0.88rem', color: 'rgba(244,228,193,0.75)', lineHeight: 1.8, whiteSpace: 'pre-wrap' }}>{note?.text}</Text>
        {verses.length > 0 && (
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.3rem' }}>
            {verses.map((v, i) => (
              <button
                key={i}
                onClick={() => { if (onNavigateVerse) onNavigateVerse(v[0], v[1], v[2]); }}
                style={{
                  background: 'rgba(200,134,26,0.1)',
                  border: '1px solid rgba(200,134,26,0.28)',
                  borderRadius: 4,
                  padding: '0.1rem 0.5rem',
                  cursor: onNavigateVerse ? 'pointer' : 'default',
                  fontFamily: "'IM Fell English', serif",
                  fontStyle: 'italic',
                  fontSize: '0.68rem',
                  color: 'var(--gold)',
                  transition: 'background 0.15s, border-color 0.15s',
                }}
                onMouseEnter={e => { if (onNavigateVerse) { e.currentTarget.style.background = 'rgba(200,134,26,0.2)'; e.currentTarget.style.borderColor = 'rgba(200,134,26,0.55)'; } }}
                onMouseLeave={e => { e.currentTarget.style.background = 'rgba(200,134,26,0.1)'; e.currentTarget.style.borderColor = 'rgba(200,134,26,0.28)'; }}
              >
                {fmtVerse(v)}
              </button>
            ))}
          </div>
        )}
        {canReply && (
          <>
            <Divider />
            <Text style={{ fontSize: '0.58rem', letterSpacing: '0.2em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.45)' }}>Replies</Text>
            {repliesLoading
              ? <Spin size="small" />
              : replies.length === 0
                ? <Text style={{ fontSize: '0.72rem', color: 'rgba(244,228,193,0.25)' }}>No replies yet.</Text>
                : replies.map((r, i) => (
                    <div key={i} style={{ padding: '0.35rem 0.5rem', borderLeft: '2px solid rgba(200,134,26,0.2)' }}>
                      <Text style={{ fontSize: '0.62rem', color: 'var(--gold)', opacity: 0.7, display: 'block' }}>{r.user}</Text>
                      <Text style={{ fontSize: '0.75rem', color: 'rgba(244,228,193,0.6)', lineHeight: 1.5 }}>{r.text}</Text>
                    </div>
                  ))
            }
            <TextArea rows={2} value={replyText} onChange={e => setReplyText(e.target.value)} placeholder="Write a reply…" style={{ resize: 'none' }} />
            <Button type="default" size="small" onClick={handleReply} loading={replying} style={{ alignSelf: 'flex-end' }}>Reply</Button>
          </>
        )}
      </div>
    </div>
  );
}

// ── Highlight card ────────────────────────────────────────────────────────────

function HighlightCard({ book, chapter, verse, color, username, onNavigate }) {
  return (
    <div
      onClick={() => onNavigate(book, chapter, verse)}
      style={{
        display: 'flex', alignItems: 'center', gap: '0.6rem',
        padding: '0.5rem 0.7rem',
        background: 'rgba(20,12,4,0.5)',
        border: '1px solid rgba(200,134,26,0.18)',
        borderRadius: 10, cursor: 'pointer',
        transition: 'border-color 0.15s',
      }}
      onMouseEnter={e => { e.currentTarget.style.borderColor = 'rgba(200,134,26,0.38)'; }}
      onMouseLeave={e => { e.currentTarget.style.borderColor = 'rgba(200,134,26,0.18)'; }}
    >
      <span style={{
        width: 10, height: 10, borderRadius: '50%',
        background: color, flexShrink: 0,
        boxShadow: `0 0 0 2px rgba(0,0,0,0.3)`,
      }} />
      <Text style={{
        fontFamily: "'IM Fell English', serif", fontStyle: 'italic',
        fontSize: '0.82rem', color: 'var(--gold)', flex: 1,
      }}>
        {book} {chapter}:{verse}
      </Text>
      {username && (
        <Tag color="gold" style={{ fontSize: '0.52rem', margin: 0, letterSpacing: '0.06em' }}>
          {username}
        </Tag>
      )}
    </div>
  );
}

// ── Filter panel ──────────────────────────────────────────────────────────────

function FilterPanel({ onApply, onClear, onClose, groupUsernames }) {
  const [sortVal,    setSortVal]    = useState('');
  const [filterType, setFilterType] = useState('');
  const [filterVal,  setFilterVal]  = useState('');

  return (
    <div style={{ position: 'absolute', inset: 0, background: 'rgba(6,4,1,0.98)', zIndex: 4, display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.65rem', padding: '0.55rem 0.6rem', borderBottom: '1px solid rgba(200,134,26,0.15)' }}>
        <Button type="text" icon={<ArrowLeftOutlined />} onClick={onClose} style={{ color: 'rgba(200,134,26,0.6)' }} />
        <Text strong style={{ fontFamily: "'Playfair Display', serif", fontSize: '0.95rem', color: 'var(--parchment)', flex: 1 }}>Filter & Sort</Text>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '0.85rem 0.6rem', display: 'flex', flexDirection: 'column', gap: '1rem' }}>
        <div>
          <Text style={{ fontSize: '0.58rem', letterSpacing: '0.22em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)', display: 'block', marginBottom: 8 }}>Sort by date</Text>
          <Select value={sortVal || undefined} placeholder="— No sort —" onChange={setSortVal} style={{ width: '100%' }}
            options={[{ value: '', label: '— No sort —' }, { value: 'desc', label: 'Newest first' }, { value: 'asc', label: 'Oldest first' }]}
          />
        </div>
        <div>
          <Text style={{ fontSize: '0.58rem', letterSpacing: '0.22em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)', display: 'block', marginBottom: 8 }}>Filter by</Text>
          <Select value={filterType || undefined} placeholder="— No filter —" onChange={v => { setFilterType(v); setFilterVal(''); }}
            style={{ width: '100%', marginBottom: 8 }}
            options={[{ value: '', label: '— No filter —' }, { value: 'book', label: 'Book' }, { value: 'title', label: 'Title' }, { value: 'date', label: 'Date' }, { value: 'user', label: 'User' }]}
          />
          {filterType === 'user'
            ? <Select value={filterVal || undefined} placeholder="Select user" onChange={setFilterVal} style={{ width: '100%' }}
                options={groupUsernames.map(n => ({ value: n, label: n }))} />
            : filterType
              ? <Input type={filterType === 'date' ? 'date' : 'text'} placeholder={filterType === 'book' ? 'e.g. Genesis' : 'Search…'} value={filterVal} onChange={e => setFilterVal(e.target.value)} />
              : null
          }
        </div>
      </div>
      <div style={{ padding: '0.6rem 0.6rem', borderTop: '1px solid rgba(200,134,26,0.12)', display: 'flex', gap: '0.5rem' }}>
        <Button type="primary" onClick={() => onApply({ sortVal, filterType, filterVal })} style={{ flex: 1 }}>Apply</Button>
        <Button onClick={() => { setSortVal(''); setFilterType(''); setFilterVal(''); onClear(); }} style={{ flex: 1 }}>Clear</Button>
      </div>
    </div>
  );
}

// ── Main NotesSidebar ─────────────────────────────────────────────────────────

export default function NotesSidebar({
  user, notes, curBook, curChapter, curVerse,
  groups, currentGroupId, onGroupChange,
  onSaveNote, onDeleteNote, onReply, onLoadReplies,
  applyFilter, clearFilter, filterActive,
  allNotes, groupNotes,
  books, chapterCount, verseCount,
  localHl, groupHighlights, groupUsernames,
  onNavigateVerse,
}) {
  const [editorOpen,   setEditorOpen]   = useState(false);
  const [editorNoteId, setEditorNoteId] = useState(null);
  const [detailNote,   setDetailNote]   = useState(null);
  const [detailId,     setDetailId]     = useState(null);
  const [showFilter,   setShowFilter]   = useState(false);
  const [replies,      setReplies]      = useState([]);
  const [repliesLoading, setRepliesLoading] = useState(false);
  const [activeTab,    setActiveTab]    = useState(() => {
    try { return localStorage.getItem('fs_notes_tab') || 'verse'; } catch { return 'verse'; }
  });

  // Derive lists
  const { verse: verseList, pub: pubList } = React.useMemo(() => {
    const verse = [], pub = [];
    const src = notes.filtered || notes.all || {};
    Object.entries(src).forEach(([id, note]) => {
      if (note.group_id) return;
      verse.push([id, note, null, false]);
    });
    if (currentGroupId) {
      const myUsername = user?.username || '';
      const groupSrc   = notes.filteredGroup || notes.group || {};
      Object.entries(groupSrc).forEach(([uname, noteMap]) => {
        Object.entries(noteMap).forEach(([id, note]) => {
          if (note.public) pub.push([id, note, uname, uname === myUsername]);
        });
      });
    }
    return { verse, pub };
  }, [notes, currentGroupId, user]);

  const openEditor = (id = null) => { setEditorNoteId(id); setEditorOpen(true); };
  const closeEditor = () => { setEditorOpen(false); setEditorNoteId(null); };

  const handleEditorSave = async (body, noteId) => {
    return await onSaveNote(body, noteId);
  };

  const openDetail = async (id) => {
    const note = notes.all[id]
      || Object.values(notes.group || {}).reduce((f, m) => f || m[id], null);
    if (!note) return;
    setDetailId(id);
    setDetailNote(note);
    if (currentGroupId) {
      setRepliesLoading(true);
      const r = await onLoadReplies(id);
      setReplies(Array.isArray(r) ? r : []);
      setRepliesLoading(false);
    }
  };

  const closeDetail = () => { setDetailId(null); setDetailNote(null); setReplies([]); };

  const handleDelete = async (id) => {
    if (!window.confirm('Delete this note?')) return;
    await onDeleteNote(id);
  };

  const verseEmpty = (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', flex: 1, padding: '2.5rem 1.5rem', textAlign: 'center', gap: '1rem' }}>
      <div style={{ fontFamily: "'IM Fell English', serif", fontStyle: 'italic', fontSize: '2rem', color: 'rgba(200,134,26,0.25)', lineHeight: 1 }}>✦</div>
      <Text style={{ fontFamily: "'Playfair Display', serif", fontSize: '0.95rem', color: 'rgba(244,228,193,0.55)', display: 'block', lineHeight: 1.4 }}>
        Your study begins here
      </Text>
      <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.72rem', color: 'rgba(244,228,193,0.28)', lineHeight: 1.65, display: 'block' }}>
        Tap <strong style={{ color: 'rgba(200,134,26,0.55)' }}>New</strong> to capture your first note.
      </Text>
      <Button
        size="small" icon={<PlusOutlined />}
        onClick={() => openEditor(null)}
        style={{ marginTop: '0.2rem', borderColor: 'rgba(200,134,26,0.4)', color: 'var(--gold)', borderRadius: 8 }}
      >
        New Note
      </Button>
    </div>
  );

  // Build flat sorted list of highlights for the Highlights tab
  const hlList = React.useMemo(() => {
    const parseKey = (key) => {
      const parts = key.split('-');
      const vs    = parseInt(parts.pop());
      const ch    = parseInt(parts.pop());
      const book  = parts.join('-');
      return { book, chapter: ch, verse: vs };
    };
    const list = currentGroupId
      ? Object.entries(groupHighlights || {}).flatMap(([uid, hl]) =>
          Object.entries(hl).map(([key, color]) => ({
            ...parseKey(key), color,
            username: groupUsernames?.[uid] || uid.slice(0, 4),
            sortKey: key,
          }))
        )
      : Object.entries(localHl || {}).map(([key, color]) => ({
          ...parseKey(key), color, username: null, sortKey: key,
        }));
    return list.sort((a, b) =>
      a.book.localeCompare(b.book) || a.chapter - b.chapter || a.verse - b.verse
    );
  }, [localHl, groupHighlights, groupUsernames, currentGroupId]);

  const tabItems = [
    {
      key: 'verse',
      label: 'Notes',
      children: (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '0.45rem', padding: verseList.length ? '0.5rem 0.4rem' : 0, flex: 1 }}>
          {verseList.length === 0
            ? verseEmpty
            : verseList.map(([id, note, owner, isOwn]) => (
                <NoteCard key={id} id={id} note={note} owner={owner} isOwn={isOwn}
                  onEdit={openEditor} onDelete={handleDelete} onOpen={openDetail}
                  onNavigateVerse={onNavigateVerse} />
              ))
          }
        </div>
      ),
    },
    {
      key: 'public',
      label: 'Group',
      children: (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '0.45rem', padding: '0.5rem 0.4rem' }}>
          {pubList.length === 0
            ? <div style={{ textAlign: 'center', padding: '2rem 1rem' }}>
                <Text style={{ fontSize: '0.75rem', color: 'rgba(244,228,193,0.25)', fontFamily: "'Lora', serif" }}>
                  {currentGroupId ? 'No public notes in this group yet.' : 'Join a group to see shared notes.'}
                </Text>
              </div>
            : pubList.map(([id, note, owner, isOwn]) => (
                <NoteCard key={id} id={id} note={note} owner={owner} isOwn={isOwn}
                  onEdit={openEditor} onDelete={handleDelete} onOpen={openDetail}
                  onNavigateVerse={onNavigateVerse} />
              ))
          }
        </div>
      ),
    },
    {
      key: 'highlights',
      label: 'Highlights',
      children: (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '0.4rem', padding: '0.5rem 0.4rem' }}>
          {hlList.length === 0
            ? <div style={{ textAlign: 'center', padding: '2rem 1rem' }}>
                <Text style={{ fontSize: '0.75rem', color: 'rgba(244,228,193,0.25)', fontFamily: "'Lora', serif" }}>
                  {currentGroupId ? 'No highlights in this group yet.' : 'No highlights yet — mark a verse while reading.'}
                </Text>
              </div>
            : hlList.map((h, i) => (
                <HighlightCard
                  key={`${h.sortKey}-${i}`}
                  book={h.book} chapter={h.chapter} verse={h.verse}
                  color={h.color} username={h.username}
                  onNavigate={onNavigateVerse || (() => {})}
                />
              ))
          }
        </div>
      ),
    },
  ];

  if (!user) {
    return (
      <div className="notes-sidebar" style={{ alignItems: 'center', justifyContent: 'center', gap: '1.2rem', padding: '2rem', textAlign: 'center' }}>
        <Text style={{ fontSize: '0.82rem', color: 'rgba(244,228,193,0.4)', lineHeight: 1.6 }}>Sign in to take notes while you read.</Text>
        <Button href="#/signin" style={{ padding: '0.6rem 1.6rem', letterSpacing: '0.15em', textTransform: 'uppercase' }}>Sign In</Button>
      </div>
    );
  }

  // Editor view — takes over the full notes section
  if (editorOpen) {
    const editorNote = editorNoteId ? (notes.all[editorNoteId] || null) : null;
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

      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0.75rem 0.6rem 0.6rem', borderBottom: '1px solid rgba(200,134,26,0.15)', flexShrink: 0 }}>
        <Title level={5} style={{ margin: 0, fontFamily: "'Playfair Display', serif", color: 'var(--parchment)' }}>Notes</Title>
        <div style={{ display: 'flex', gap: 4, alignItems: 'center' }}>
          <Button
            type="text" size="small" icon={<FilterOutlined />}
            onClick={() => setShowFilter(true)}
            style={{ color: filterActive ? 'var(--gold)' : 'rgba(200,134,26,0.55)' }}
          />
          <Button
            size="small" icon={<PlusOutlined />}
            onClick={() => openEditor(null)}
            style={{ borderColor: 'rgba(200,134,26,0.4)', color: 'var(--gold)' }}
          >
            New
          </Button>
        </div>
      </div>

      {/* Group selector */}
      {groups.length > 0 && (
        <div style={{ padding: '0.3rem 0.55rem', borderBottom: '1px solid rgba(200,134,26,0.1)' }}>
          <Select
            value={currentGroupId || ''}
            onChange={onGroupChange}
            style={{ width: '100%' }}
            size="small"
            options={[
              { value: '', label: 'Personal notes' },
              ...groups.map(g => ({ value: g.id, label: g.title })),
            ]}
          />
        </div>
      )}

      {/* Notes list or detail */}
      {detailNote
        ? <NoteDetail
            note={detailNote} noteId={detailId}
            onBack={closeDetail}
            canReply={!!currentGroupId}
            onReply={onReply}
            replies={replies} repliesLoading={repliesLoading}
            onNavigateVerse={onNavigateVerse}
          />
        : <div style={{ flex: 1, overflowY: 'auto', display: 'flex', flexDirection: 'column' }}>
            <Tabs
              activeKey={activeTab}
              onChange={key => { try { localStorage.setItem('fs_notes_tab', key); } catch {} setActiveTab(key); }}
              items={tabItems}
              size="small"
              style={{ padding: '0 0.25rem', display: 'flex', flexDirection: 'column', height: '100%' }}
            />
          </div>
      }

      {/* Filter panel */}
      {showFilter && (
        <FilterPanel
          onApply={(params) => { applyFilter({ ...params, activeTab }); setShowFilter(false); }}
          onClear={() => { clearFilter(); setShowFilter(false); }}
          onClose={() => setShowFilter(false)}
          groupUsernames={Object.keys(notes.group || {})}
        />
      )}
    </div>
  );
}
