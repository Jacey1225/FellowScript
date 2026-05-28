import React, { useState, useCallback } from 'react';
import {
  Button, Tabs, Input, Select, Form, Checkbox, Typography,
  Empty, Spin, Space, Divider, Tag, Avatar,
} from 'antd';
import {
  PlusOutlined, EditOutlined, DeleteOutlined, FilterOutlined,
  ArrowLeftOutlined, ReloadOutlined,
} from '@ant-design/icons';
import { verseRefLabel } from '../utils.js';

const { TextArea } = Input;
const { Text, Title } = Typography;

// ── Note form ─────────────────────────────────────────────────────────────────

function NoteForm({ note, onSave, onCancel, curBook, curChapter, curVerse, groups, currentGroupId }) {
  const [form] = Form.useForm();
  const [saving, setSaving] = useState(false);

  const initialValues = note
    ? {
        title:  note.title || '',
        text:   note.text  || '',
        public: !!note.public,
        bookS:  note.verses?.[0]?.[0] || '',
        chS:    note.verses?.[0]?.[1]  || '',
        vsS:    note.verses?.[0]?.[2]  || '',
        bookE:  note.verses?.[1]?.[0] || '',
        chE:    note.verses?.[1]?.[1]  || '',
        vsE:    note.verses?.[1]?.[2]  || '',
      }
    : {
        bookS: curBook    || '',
        chS:   curChapter || '',
        vsS:   curVerse   || '',
        public: false,
      };

  const handleSave = async () => {
    const vals = form.getFieldsValue();
    setSaving(true);
    await onSave(vals);
    setSaving(false);
  };

  return (
    <div style={{ padding: '0.9rem 1.1rem', borderBottom: '1px solid rgba(200,134,26,0.12)', background: 'rgba(200,134,26,0.04)' }}>
      <Text style={{ fontSize: '0.62rem', letterSpacing: '0.2em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.55)', display: 'block', marginBottom: '0.65rem' }}>
        {note ? 'Edit Note' : 'New Note'}
      </Text>
      <Form form={form} layout="vertical" initialValues={initialValues} size="small">
        <Form.Item name="title" style={{ marginBottom: 8 }}>
          <Input placeholder="Title" />
        </Form.Item>
        <Form.Item name="text" style={{ marginBottom: 8 }}>
          <TextArea placeholder="Your note…" autoSize={{ minRows: 4, maxRows: 14 }} style={{ resize: 'vertical' }} />
        </Form.Item>
        <Text style={{ fontSize: '0.58rem', letterSpacing: '0.15em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.4)' }}>Verse range</Text>
        <div style={{ display: 'flex', gap: 4, marginTop: 4, marginBottom: 4 }}>
          <Form.Item name="bookS" style={{ flex: 2, marginBottom: 0 }}><Input placeholder="Book" /></Form.Item>
          <Form.Item name="chS"   style={{ flex: 1, marginBottom: 0 }}><Input placeholder="Ch" /></Form.Item>
          <Form.Item name="vsS"   style={{ flex: 1, marginBottom: 0 }}><Input placeholder="Vs" /></Form.Item>
        </div>
        <div style={{ display: 'flex', gap: 4, marginBottom: 8 }}>
          <Form.Item name="bookE" style={{ flex: 2, marginBottom: 0 }}><Input placeholder="Book" /></Form.Item>
          <Form.Item name="chE"   style={{ flex: 1, marginBottom: 0 }}><Input placeholder="Ch" /></Form.Item>
          <Form.Item name="vsE"   style={{ flex: 1, marginBottom: 0 }}><Input placeholder="Vs" /></Form.Item>
        </div>
        <Form.Item name="public" valuePropName="checked" style={{ marginBottom: 8 }}>
          <Checkbox style={{ color: 'rgba(244,228,193,0.55)', fontSize: '0.72rem' }}>Public (share with group)</Checkbox>
        </Form.Item>
      </Form>
      <Space style={{ width: '100%' }}>
        <Button type="primary" onClick={handleSave} loading={saving} style={{ flex: 1 }}>Save</Button>
        <Button onClick={onCancel} style={{ flex: 1 }}>Cancel</Button>
      </Space>
    </div>
  );
}

// ── Note card ─────────────────────────────────────────────────────────────────

function NoteCard({ id, note, owner, isOwn, onEdit, onDelete, onOpen }) {
  const ref = verseRefLabel(note.verses);
  const canEdit = !owner || isOwn;

  return (
    <div
      className="note-card ant-card"
      style={{ border: '1px solid rgba(200,134,26,0.18)', background: 'rgba(20,12,4,0.5)', padding: '0.85rem 0.95rem', borderRadius: 10, cursor: 'pointer', marginBottom: 0, transition: 'border-color 0.2s' }}
      onClick={() => onOpen(id)}
    >
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: '0.5rem', marginBottom: '0.4rem' }}>
        <Text strong style={{ fontFamily: "'Lora', serif", fontSize: '0.85rem', color: 'var(--parchment)', lineHeight: 1.3 }}>
          {note.title || 'Untitled'}
          {note.public && <Tag style={{ marginLeft: 6, fontSize: '0.52rem', letterSpacing: '0.12em' }}>Public</Tag>}
          {owner && <Tag color="gold" style={{ marginLeft: 4, fontSize: '0.52rem' }}>{owner}</Tag>}
        </Text>
        {canEdit && (
          <Space size={2} onClick={e => e.stopPropagation()}>
            <Button type="text" size="small" icon={<EditOutlined />} onClick={() => onEdit(id)}
              style={{ color: 'rgba(200,134,26,0.45)', padding: '0 4px' }} />
            <Button type="text" size="small" icon={<DeleteOutlined />} onClick={() => onDelete(id)}
              style={{ color: 'rgba(200,134,26,0.45)', padding: '0 4px' }} />
          </Space>
        )}
      </div>
      {ref && <Text style={{ fontFamily: "'IM Fell English', serif", fontStyle: 'italic', fontSize: '0.72rem', color: 'var(--gold)', display: 'block', marginBottom: '0.45rem' }}>{ref}</Text>}
      <Text style={{ fontSize: '0.8rem', color: 'rgba(244,228,193,0.55)', lineHeight: 1.6, display: '-webkit-box', WebkitLineClamp: 3, WebkitBoxOrient: 'vertical', overflow: 'hidden' }}>
        {note.text}
      </Text>
    </div>
  );
}

// ── Note detail ───────────────────────────────────────────────────────────────

function NoteDetail({ note, noteId, onBack, canReply, onReply, replies, repliesLoading }) {
  const [replyText, setReplyText] = useState('');
  const [replying, setReplying]   = useState(false);
  const ref = verseRefLabel(note?.verses);

  const handleReply = async () => {
    if (!replyText.trim()) return;
    setReplying(true);
    await onReply(noteId, replyText);
    setReplyText('');
    setReplying(false);
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', flex: 1, overflow: 'hidden' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.65rem', padding: '0.85rem 1.1rem', borderBottom: '1px solid rgba(200,134,26,0.15)', flexShrink: 0 }}>
        <Button type="text" icon={<ArrowLeftOutlined />} onClick={onBack} style={{ color: 'rgba(200,134,26,0.6)', padding: '0 4px' }} />
        <Text strong style={{ fontFamily: "'Playfair Display', serif", fontSize: '0.95rem', color: 'var(--parchment)', flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {note?.title || 'Note'}
        </Text>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '1.2rem 1.1rem', display: 'flex', flexDirection: 'column', gap: '0.9rem' }}>
        {ref && <Text style={{ fontFamily: "'IM Fell English', serif", fontStyle: 'italic', fontSize: '0.78rem', color: 'var(--gold)' }}>{ref}</Text>}
        <Text style={{ fontSize: '0.88rem', color: 'rgba(244,228,193,0.75)', lineHeight: 1.8, whiteSpace: 'pre-wrap' }}>{note?.text}</Text>
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
            <TextArea
              rows={2} value={replyText} onChange={e => setReplyText(e.target.value)}
              placeholder="Write a reply…" style={{ resize: 'none' }}
            />
            <Button type="default" size="small" onClick={handleReply} loading={replying} style={{ alignSelf: 'flex-end' }}>Reply</Button>
          </>
        )}
      </div>
    </div>
  );
}

// ── Filter panel ──────────────────────────────────────────────────────────────

function FilterPanel({ onApply, onClear, onClose, groupUsernames }) {
  const [sortVal,     setSortVal]     = useState('');
  const [filterType,  setFilterType]  = useState('');
  const [filterVal,   setFilterVal]   = useState('');

  return (
    <div style={{ position: 'absolute', inset: 0, background: 'rgba(6,4,1,0.98)', zIndex: 4, display: 'flex', flexDirection: 'column' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.65rem', padding: '0.85rem 1.1rem', borderBottom: '1px solid rgba(200,134,26,0.15)' }}>
        <Button type="text" icon={<ArrowLeftOutlined />} onClick={onClose} style={{ color: 'rgba(200,134,26,0.6)' }} />
        <Text strong style={{ fontFamily: "'Playfair Display', serif", fontSize: '0.95rem', color: 'var(--parchment)', flex: 1 }}>Filter & Sort</Text>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '1.1rem', display: 'flex', flexDirection: 'column', gap: '1.2rem' }}>
        <div>
          <Text style={{ fontSize: '0.58rem', letterSpacing: '0.22em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)', display: 'block', marginBottom: 8 }}>Sort by date</Text>
          <Select
            value={sortVal || undefined}
            placeholder="— No sort —"
            onChange={setSortVal}
            style={{ width: '100%' }}
            options={[
              { value: '',     label: '— No sort —' },
              { value: 'desc', label: 'Newest first' },
              { value: 'asc',  label: 'Oldest first' },
            ]}
          />
        </div>
        <div>
          <Text style={{ fontSize: '0.58rem', letterSpacing: '0.22em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)', display: 'block', marginBottom: 8 }}>Filter by</Text>
          <Select
            value={filterType || undefined}
            placeholder="— No filter —"
            onChange={v => { setFilterType(v); setFilterVal(''); }}
            style={{ width: '100%', marginBottom: 8 }}
            options={[
              { value: '',      label: '— No filter —' },
              { value: 'book',  label: 'Book' },
              { value: 'title', label: 'Title' },
              { value: 'date',  label: 'Date' },
              { value: 'user',  label: 'User' },
            ]}
          />
          {filterType === 'user'
            ? <Select
                value={filterVal || undefined}
                placeholder="Select user"
                onChange={setFilterVal}
                style={{ width: '100%' }}
                options={groupUsernames.map(n => ({ value: n, label: n }))}
              />
            : filterType
              ? <Input
                  type={filterType === 'date' ? 'date' : 'text'}
                  placeholder={filterType === 'book' ? 'e.g. Genesis' : 'Search…'}
                  value={filterVal}
                  onChange={e => setFilterVal(e.target.value)}
                />
              : null
          }
        </div>
      </div>
      <div style={{ padding: '0.9rem 1.1rem', borderTop: '1px solid rgba(200,134,26,0.12)', display: 'flex', gap: '0.5rem' }}>
        <Button type="primary" onClick={() => onApply({ sortVal, filterType, filterVal })} style={{ flex: 1 }}>Apply</Button>
        <Button onClick={() => { setSortVal(''); setFilterType(''); setFilterVal(''); onClear(); }} style={{ flex: 1 }}>Clear</Button>
      </div>
    </div>
  );
}

// ── Main NotesSidebar ─────────────────────────────────────────────────────────

export default function NotesSidebar({
  user, notes, onClose, curBook, curChapter, curVerse,
  groups, currentGroupId, onGroupChange,
  onSaveNote, onDeleteNote, onReply, onLoadReplies,
  applyFilter, clearFilter, filterActive,
  allNotes, groupNotes, groupUsernames,
}) {
  const [showForm,    setShowForm]    = useState(false);
  const [editingId,   setEditingId]   = useState(null);
  const [detailNote,  setDetailNote]  = useState(null);
  const [detailId,    setDetailId]    = useState(null);
  const [showFilter,  setShowFilter]  = useState(false);
  const [replies,     setReplies]     = useState([]);
  const [repliesLoading, setRepliesLoading] = useState(false);
  const [activeTab,   setActiveTab]   = useState('verse');

  // Derive lists
  const { verse: verseList, pub: pubList } = React.useMemo(() => {
    const verse = [], pub = [];
    const src = notes.filtered || notes.all || {};
    Object.entries(src).forEach(([id, note]) => {
      if (note.group_id) return;
      verse.push([id, note, null, false]);
      if (note.public) pub.push([id, note, null, false]);
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

  const openEdit = (id) => {
    setEditingId(id);
    setShowForm(true);
  };

  const handleSave = async (vals) => {
    const note = editingId ? (notes.all[editingId] || null) : null;
    const bookS = vals.bookS?.trim() || '';
    const chS   = parseInt(vals.chS) || null;
    const vsS   = parseInt(vals.vsS) || null;
    const bookE = vals.bookE?.trim() || '';
    const chE   = parseInt(vals.chE) || null;
    const vsE   = parseInt(vals.vsE) || null;
    const hasStart = bookS && chS && vsS;
    const hasEnd   = bookE && chE && vsE;

    const body = {
      user:     user.user_id,
      group_id: editingId
        ? (note?.group_id || '')
        : (vals.public && currentGroupId ? currentGroupId : ''),
      replies:  editingId ? (note?.replies || []) : [],
      title:    vals.title?.trim() || 'Note',
      text:     vals.text?.trim() || '',
      public:   !!vals.public,
      verses:   hasStart
        ? [[bookS, chS, vsS], hasEnd ? [bookE, chE, vsE] : [bookS, chS, vsS]]
        : [[], []],
    };

    const ok = await onSaveNote(body, editingId || null);
    if (ok) { setShowForm(false); setEditingId(null); }
  };

  const handleDelete = async (id) => {
    if (!window.confirm('Delete this note?')) return;
    await onDeleteNote(id);
  };

  const tabItems = [
    {
      key: 'verse',
      label: 'Notes',
      children: (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '0.6rem', padding: '0.7rem' }}>
          {verseList.length === 0
            ? <Empty description={<span style={{ color: 'rgba(244,228,193,0.25)', fontSize: '0.75rem' }}>No notes yet.</span>} image={Empty.PRESENTED_IMAGE_SIMPLE} />
            : verseList.map(([id, note, owner, isOwn]) => (
                <NoteCard key={id} id={id} note={note} owner={owner} isOwn={isOwn}
                  onEdit={openEdit} onDelete={handleDelete} onOpen={openDetail} />
              ))
          }
        </div>
      ),
    },
    {
      key: 'public',
      label: 'Group',
      children: (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '0.6rem', padding: '0.7rem' }}>
          {pubList.length === 0
            ? <Empty description={<span style={{ color: 'rgba(244,228,193,0.25)', fontSize: '0.75rem' }}>{currentGroupId ? 'No public notes in this group.' : 'No public notes yet.'}</span>} image={Empty.PRESENTED_IMAGE_SIMPLE} />
            : pubList.map(([id, note, owner, isOwn]) => (
                <NoteCard key={id} id={id} note={note} owner={owner} isOwn={isOwn}
                  onEdit={openEdit} onDelete={handleDelete} onOpen={openDetail} />
              ))
          }
        </div>
      ),
    },
  ];

  if (!user) {
    return (
      <div className="notes-sidebar" style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: '1.2rem', padding: '2rem', textAlign: 'center' }}>
        <Text style={{ fontSize: '0.82rem', color: 'rgba(244,228,193,0.4)', lineHeight: 1.6 }}>Sign in to take notes while you read.</Text>
        <Button href="#/signin" style={{ padding: '0.6rem 1.6rem', letterSpacing: '0.15em', textTransform: 'uppercase' }}>Sign In</Button>
      </div>
    );
  }

  return (
    <div className="notes-sidebar" style={{ position: 'relative' }}>
      <div className="sidebar-resize-handle" />

      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '1.2rem 1.2rem 0.8rem', borderBottom: '1px solid rgba(200,134,26,0.15)', flexShrink: 0 }}>
        <Title level={5} style={{ margin: 0, fontFamily: "'Playfair Display', serif", color: 'var(--parchment)' }}>Notes</Title>
        <Space size={4}>
          <Button
            type="text" size="small" icon={<FilterOutlined />}
            onClick={() => setShowFilter(true)}
            style={{ color: filterActive ? 'var(--gold)' : 'rgba(200,134,26,0.55)' }}
          />
          <Button
            size="small" icon={<PlusOutlined />}
            onClick={() => { setEditingId(null); setShowForm(v => !v); }}
            style={{ borderColor: 'rgba(200,134,26,0.4)', color: 'var(--gold)' }}
          >
            New
          </Button>
        </Space>
      </div>

      {/* Group selector */}
      {groups.length > 0 && (
        <div style={{ padding: '0.45rem 1.1rem', borderBottom: '1px solid rgba(200,134,26,0.1)' }}>
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

      {/* Form */}
      {showForm && (
        <NoteForm
          note={editingId ? notes.all[editingId] : null}
          onSave={handleSave}
          onCancel={() => { setShowForm(false); setEditingId(null); }}
          curBook={curBook} curChapter={curChapter} curVerse={curVerse}
          groups={groups} currentGroupId={currentGroupId}
        />
      )}

      {/* Notes list or detail */}
      {detailNote
        ? <NoteDetail
            note={detailNote} noteId={detailId}
            onBack={closeDetail}
            canReply={!!currentGroupId}
            onReply={onReply}
            replies={replies} repliesLoading={repliesLoading}
          />
        : <div style={{ flex: 1, overflowY: 'auto', display: 'flex', flexDirection: 'column' }}>
            <Tabs
              activeKey={activeTab}
              onChange={setActiveTab}
              items={tabItems}
              size="small"
              style={{ padding: '0 0.6rem' }}
            />
          </div>
      }

      {/* Filter panel */}
      {showFilter && (
        <FilterPanel
          onApply={(params) => { applyFilter(params); setShowFilter(false); }}
          onClear={() => { clearFilter(); setShowFilter(false); }}
          onClose={() => setShowFilter(false)}
          groupUsernames={Object.keys(notes.group || {})}
        />
      )}
    </div>
  );
}
