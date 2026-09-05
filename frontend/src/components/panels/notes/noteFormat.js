// Shared formatting/validation helpers for the Notes panel's sub-components
// (readability #10, 20260904-frontend-arch-sweep -- split out of the former
// monolithic NotesPanel.jsx so NoteCard/NoteDetail/NoteEditor/FilterPanel can
// each import only what they need).
import { stripHtml as sanitizeStripHtml } from '../../RichText.jsx';

// Format a single [book, chapter, verse] triple into a display string
export function fmtVerse([b, c, v]) { return `${b} ${c}:${v}`; }

// Format a note's creation timestamp into a compact, human-readable label
export function fmtDate(ts) {
  if (!ts) return '';
  const d = new Date(ts);
  if (isNaN(d.getTime())) return '';
  const now = new Date();
  if (d.toDateString() === now.toDateString()) return 'Today';
  const yesterday = new Date(now); yesterday.setDate(now.getDate() - 1);
  if (d.toDateString() === yesterday.toDateString()) return 'Yesterday';
  return d.toLocaleDateString('en-US', {
    month: 'short', day: 'numeric',
    ...(d.getFullYear() !== now.getFullYear() ? { year: 'numeric' } : {}),
  });
}

// Return an array of valid verse triples from a note's verses field.
export function validVerses(verses) {
  if (!Array.isArray(verses)) return [];
  return verses.filter(v => Array.isArray(v) && v.length >= 3 && v[0]);
}

export const stripHtml = sanitizeStripHtml;
export const TEXT_COLORS = ['#c8861a', '#e07070', '#6dbf7e', '#7eb8e0', '#b07ee0', '#f4e4c1'];

// One shared implementation of the gold-hover mouse handlers that used to be
// duplicated near-verbatim across the formatting toolbar, the color
// swatches, and the verse-reference chips (readability #10's specific
// complaint) -- callers supply only the two style deltas (hover vs. base).
export function hoverStyleHandlers(hoverStyle, baseStyle) {
  return {
    onMouseEnter: e => Object.assign(e.currentTarget.style, hoverStyle),
    onMouseLeave: e => Object.assign(e.currentTarget.style, baseStyle),
  };
}
