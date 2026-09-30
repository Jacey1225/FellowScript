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

// ── Note length counting ─────────────────────────────────────────────────────
// The server caps `text` by Python len() (Unicode code points) of the string
// exactly as sent, and the editor sends innerHTML. Count the same string the
// same way: [...s].length (code points), never s.length (UTF-16 units). The
// limit itself comes from the server's usage endpoint (note_chars.limit);
// nothing here hardcodes it.
export const NOTE_WARN_RATIO = 0.9;

export function countCodePoints(s) {
  let n = 0;
  for (const _ of s || '') n += 1; // eslint-disable-line no-unused-vars
  return n;
}

// Approximate words from the visible text (tags/entities stripped). Display only.
export function approxWords(html) {
  const tmp = document.createElement('div');
  tmp.innerHTML = html || '';
  const t = (tmp.textContent || '').trim();
  return t ? t.split(/\s+/).length : 0;
}

// 'ok' | 'warn' | 'over'
export function noteLimitState(count, limit) {
  if (!limit) return 'ok';
  if (count > limit) return 'over';
  if (count >= limit * NOTE_WARN_RATIO) return 'warn';
  return 'ok';
}

// Mirrors the server's grandfather rule: blocked iff new > limit AND
// (create OR new > stored length).
export function isNoteSaveBlocked(count, limit, origCount, isEdit) {
  if (!limit || count <= limit) return false;
  return !isEdit || count > origCount;
}
