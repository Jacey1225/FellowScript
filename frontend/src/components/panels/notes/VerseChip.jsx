import React from 'react';
import { fmtVerse, hoverStyleHandlers } from './noteFormat.js';

// One shared verse-reference chip, used by both NoteCard and NoteDetail
// (readability #10, 20260904-frontend-arch-sweep) -- these two previously
// carried near-identical copies of this button's markup and hover handlers.
// `bordered` captures the one real visual difference between the two call
// sites (NoteDetail's chip has a visible border, NoteCard's doesn't).
export default function VerseChip({ verse, onNavigateVerse, bordered = false }) {
  // Same style deltas regardless of `bordered` -- matches the pre-split
  // behavior exactly (NoteCard's unbordered chip also set borderColor on
  // hover/leave; it was just invisible there since border was `none`).
  const hoverHandlers = hoverStyleHandlers(
    onNavigateVerse
      ? { background: 'rgba(255,198,26,0.2)', borderColor: 'rgba(255,255,255,0.33)' }
      : {},
    { background: 'rgba(255,198,26,0.1)', borderColor: 'rgba(255,255,255,0.168)' }
  );

  return (
    <button
      onClick={() => { if (onNavigateVerse) onNavigateVerse(verse[0], verse[1], verse[2]); }}
      style={{
        background: 'rgba(255,198,26,0.1)',
        border: bordered ? '1px solid rgba(255,255,255,0.168)' : 'none',
        borderRadius: 4,
        padding: '0.1rem 0.5rem',
        cursor: onNavigateVerse ? 'pointer' : 'default',
        fontFamily: "'Lora', serif",
        fontStyle: 'italic',
        fontSize: '0.68rem',
        color: 'var(--gold)',
        transition: 'background 0.15s, border-color 0.15s',
      }}
      {...hoverHandlers}
    >
      {fmtVerse(verse)}
    </button>
  );
}
