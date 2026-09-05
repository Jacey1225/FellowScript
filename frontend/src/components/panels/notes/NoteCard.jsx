import React from 'react';
import { Button, Typography, Tag } from 'antd';
import { EditOutlined, DeleteOutlined } from '@ant-design/icons';
import VerseChip from './VerseChip.jsx';
import { fmtDate, validVerses, stripHtml } from './noteFormat.js';

const { Text } = Typography;

// ── Note card ─────────────────────────────────────────────────────────────────
export default function NoteCard({ id, note, owner, isOwn, onEdit, onDelete, onOpen, onNavigateVerse }) {
  const verses  = validVerses(note.verses);
  // A personal note (no owner label shown) is always the caller's own, and
  // an author can always edit/delete their own note. A non-owner group
  // member can now also edit (but never delete) if the note's author left
  // `public` (edit-permission) on -- the server enforces the same split in
  // update_note (edit branch) / delete_note (still owner-only); this only
  // drives which affordance(s) appear.
  const canDelete = !owner || isOwn;
  const canEdit   = canDelete || note.public;

  return (
    <div
      // Background/border come from reader-dock.css's desktop-scoped glass
      // override (item 2, 20260825-reader-dock-rail-polish) — the shared
      // global.css `.note-card.ant-card` rule this used to lean on paints a
      // flat opaque --card-bg fill, which NotesSidebar.jsx's mobile NoteCard
      // still intentionally uses; only inline geometry lives here now.
      className="note-card ant-card"
      style={{ padding: '0.6rem 0.65rem', borderRadius: 14, cursor: 'pointer', marginBottom: 0, transition: 'border-color 0.2s' }}
      onClick={() => onOpen(id)}
    >
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: '0.5rem', marginBottom: '0.4rem' }}>
        <Text strong style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.85rem', color: 'var(--parchment)', lineHeight: 1.3 }}>
          {note.title || 'Untitled'}
          {/* Edit-permission indicator, not a visibility flag anymore -- only
              meaningful (and only shown) on a group note. */}
          {owner && note.public && <Tag style={{ marginLeft: 6, fontSize: '0.52rem', letterSpacing: '0.12em' }}>Editable</Tag>}
          {owner && <Tag color="gold" style={{ marginLeft: 4, fontSize: '0.52rem' }}>{owner}</Tag>}
        </Text>
        {(canEdit || canDelete) && (
          <div style={{ display: 'flex', gap: 2, flexShrink: 0 }} onClick={e => e.stopPropagation()}>
            {canEdit && (
              <Button type="text" size="small" icon={<EditOutlined />} onClick={() => onEdit(id)}
                style={{ color: 'rgba(255,198,26,0.45)', padding: '0 4px' }} />
            )}
            {canDelete && (
              <Button type="text" size="small" icon={<DeleteOutlined />} onClick={() => onDelete(id)}
                style={{ color: 'rgba(255,198,26,0.45)', padding: '0 4px' }} />
            )}
          </div>
        )}
      </div>
      {verses.length > 0 && (
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.3rem', marginBottom: '0.45rem' }} onClick={e => e.stopPropagation()}>
          {verses.map((v, i) => (
            <VerseChip key={i} verse={v} onNavigateVerse={onNavigateVerse} />
          ))}
        </div>
      )}
      <p style={{ margin: 0, fontSize: '0.8rem', color: 'rgba(242,242,242,0.55)', lineHeight: 1.6, display: '-webkit-box', WebkitLineClamp: 3, WebkitBoxOrient: 'vertical', overflow: 'hidden', maxHeight: '3.84rem' }}>
        {stripHtml(note.text)}
      </p>
      {(note.created_at || note.timestamp) && (
        <p style={{ margin: '0.35rem 0 0', fontSize: '0.62rem', color: 'rgba(242,242,242,0.28)', textAlign: 'right', fontFamily: "'Inter', sans-serif", letterSpacing: '0.02em' }}>
          {fmtDate(note.created_at || note.timestamp)}
        </p>
      )}
    </div>
  );
}
