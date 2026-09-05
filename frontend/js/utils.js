// Escaping coverage here is kept identical to the React app's escHtml
// (frontend/src/utils.js) on purpose -- same name, same "safe for innerHTML"
// contract, both surfaces. If you widen/narrow this escaping, make the
// matching edit there too (readability #H15, 20260904-frontend-arch-sweep).
export function escHtml(s) {
  return String(s || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// Proper three-way comparator for message-timestamp sorting (logic-errors
// #5, 20260904-frontend-arch-sweep) -- mirrors frontend/src/utils.js's
// compareTimestamps. Returns 0 for equal values instead of the
// `a > b ? 1 : -1` idiom this file used previously, which is not a valid
// Array#sort comparator (never returns 0).
export function compareTimestamps(a, b) {
  const ta = (a && a.timestamp) || '';
  const tb = (b && b.timestamp) || '';
  if (ta > tb) return 1;
  if (ta < tb) return -1;
  return 0;
}

export function hexWithAlpha(hex, alpha) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `rgba(${r},${g},${b},${alpha})`;
}

// Defensive guard against the exact "4 fake Untitled/General notes" failure
// mode (pre-8710a27a): back then, loadNotes/_loadGroupNotes set state to the
// *whole* paginated envelope ({notes, next_cursor_created_at, next_cursor_id,
// has_more}) instead of unwrapping payload.notes, so each of those 4
// envelope keys got rendered as if it were a note id -- none has .title/
// .text/.verses, so every "note" showed up as an empty "Untitled" card
// grouped under "General" (the fallback for a missing verse tag).
//
// `payload.notes ?? {}` (used at the call sites) already unwraps correctly
// against the current envelope shape. This helper adds one more layer: only
// trust payload.notes as the notes map when it's actually present *and* an
// object -- any other shape (missing key, or a non-object value, e.g. a
// regression back to serving the bare envelope some other way) is treated as
// "no notes" rather than risking that same fabricated-row symptom again.
export function unwrapNotesEnvelope(payload) {
  return payload && typeof payload.notes === 'object' && payload.notes !== null
    ? payload.notes
    : {};
}

export function verseRefLabel(verses) {
  if (!verses || !verses[0] || verses[0].length === 0) return '';
  const [bs, cs, vs] = verses[0];
  const [be, ce, ve] = verses[1] || [];
  const start = `${bs} ${cs}:${vs}`;
  const end   = be ? ` – ${be} ${ce}:${ve}` : '';
  return start + end;
}
