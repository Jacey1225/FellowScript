import React from 'react';
import { Select, Typography } from 'antd';
import { useHighlightsPanel } from '../../context/ReaderPanelContexts.jsx';

const { Text, Title } = Typography;

// ── Highlight card ────────────────────────────────────────────────────────────

function HighlightCard({ book, chapter, verse, color, username, onNavigate }) {
  return (
    <div
      onClick={() => onNavigate(book, chapter, verse)}
      style={{
        display: 'flex', alignItems: 'center', gap: '0.6rem',
        padding: '0.5rem 0.7rem',
        background: 'rgba(20,12,4,0.5)',
        border: 'none',
        borderRadius: 14, cursor: 'pointer',
        transition: 'background 0.15s',
      }}
      onMouseEnter={e => { e.currentTarget.style.background = 'rgba(20,12,4,0.75)'; }}
      onMouseLeave={e => { e.currentTarget.style.background = 'rgba(20,12,4,0.5)'; }}
    >
      <span style={{
        width: 10, height: 10, borderRadius: '50%',
        background: color, flexShrink: 0,
        boxShadow: `0 0 0 2px rgba(0,0,0,0.3)`,
      }} />
      <Text style={{
        fontFamily: "'Lora', serif", fontStyle: 'italic',
        fontSize: '0.82rem', color: 'var(--gold)', flex: 1,
      }}>
        {book} {chapter}:{verse}
      </Text>
      {username && (
        <span style={{
          background: 'rgba(255,198,26,0.15)', color: 'var(--gold)',
          fontSize: '0.52rem', letterSpacing: '0.06em', borderRadius: 4,
          padding: '0.1rem 0.4rem',
        }}>
          {username}
        </span>
      )}
    </div>
  );
}

// ── Highlights panel ──────────────────────────────────────────────────────────
// Dockview panel: the "Highlights" tab of the old combined NotesSidebar,
// extracted so it can be independently docked. Gets its own copy of the
// group-selector (same shared currentGroupId/onGroupChange as NotesPanel) so
// it isn't stranded without a way to change groups once undocked from Notes.

export default function HighlightsPanel() {
  const {
    user, currentGroupId, groups, onGroupChange, onNavigateVerse,
    localHl, groupHighlights, groupUsernames,
  } = useHighlightsPanel() || {};

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

  const groupSelector = (groups || []).length > 0 ? (
    <Select
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
        <Text style={{ fontSize: '0.82rem', color: 'rgba(242,242,242,0.4)', lineHeight: 1.6 }}>Sign in to see your verse highlights.</Text>
        <a href="#/signin" className="ant-btn" style={{ padding: '0.6rem 1.6rem', letterSpacing: '0.15em', textTransform: 'uppercase' }}>Sign In</a>
      </div>
    );
  }

  return (
    <div className="notes-sidebar">
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0.95rem 0.6rem 0.8rem', borderBottom: '1px solid rgba(255,255,255,0.072)', flexShrink: 0, gap: '0.5rem' }}>
        <Title level={5} style={{ margin: 0, fontFamily: "'Space Grotesk', sans-serif", fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.03em', color: 'var(--parchment)' }}>Highlights</Title>
        {groupSelector}
      </div>

      <div style={{ flex: 1, overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: '0.4rem', padding: '0.5rem 0.4rem' }}>
        {hlList.length === 0
          ? <div style={{ textAlign: 'center', padding: '2rem 1rem' }}>
              <Text style={{ fontSize: '0.75rem', color: 'rgba(242,242,242,0.25)', fontFamily: "'Inter', sans-serif" }}>
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
    </div>
  );
}
