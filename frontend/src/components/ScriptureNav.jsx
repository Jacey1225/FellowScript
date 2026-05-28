import React from 'react';
import { Select, Typography } from 'antd';

const { Text } = Typography;

const LABEL_STYLE = {
  fontFamily: "'Lora', serif",
  fontSize: '0.6rem',
  letterSpacing: '0.22em',
  textTransform: 'uppercase',
  color: 'rgba(200,134,26,0.55)',
  whiteSpace: 'nowrap',
};

const GROUP_STYLE = {
  display: 'flex',
  alignItems: 'center',
  gap: '0.5rem',
  padding: '0 1.2rem',
  borderRight: '1px solid rgba(200,134,26,0.18)',
  height: '100%',
};

export default function ScriptureNav({
  books, curBook, curChapter, verseNums, curVerse,
  onBookChange, onChapterChange, onVerseChange,
  chapterCount,
}) {
  const chapterOptions = curBook
    ? Array.from({ length: chapterCount }, (_, i) => ({ value: i + 1, label: `Chapter ${i + 1}` }))
    : [];

  const verseOptions = verseNums.map(n => ({ value: n, label: `Verse ${n}` }));

  return (
    <div className="scripture-nav-bar">
      <div style={{ ...GROUP_STYLE }}>
        <Text style={LABEL_STYLE}>Book</Text>
        <Select
          showSearch
          placeholder="— Book —"
          value={curBook || undefined}
          onChange={onBookChange}
          options={books.map(b => ({ value: b, label: b }))}
          style={{ minWidth: 140 }}
          size="small"
          variant="borderless"
          popupMatchSelectWidth={false}
        />
      </div>

      <div style={{ ...GROUP_STYLE }}>
        <Text style={LABEL_STYLE}>Ch</Text>
        <Select
          placeholder="—"
          value={curChapter || undefined}
          onChange={onChapterChange}
          options={chapterOptions}
          disabled={!curBook}
          style={{ minWidth: 110 }}
          size="small"
          variant="borderless"
          popupMatchSelectWidth={false}
        />
      </div>

      <div style={{ ...GROUP_STYLE, borderRight: 'none' }}>
        <Text style={LABEL_STYLE}>Vs</Text>
        <Select
          placeholder="—"
          value={curVerse || undefined}
          onChange={onVerseChange}
          options={verseOptions}
          disabled={!curChapter || verseNums.length === 0}
          style={{ minWidth: 100 }}
          size="small"
          variant="borderless"
          popupMatchSelectWidth={false}
        />
      </div>
    </div>
  );
}
