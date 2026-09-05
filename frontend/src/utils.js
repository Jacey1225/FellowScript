// Escaping coverage here is kept identical to the legacy tree's escHtml
// (frontend/js/utils.js) on purpose -- same name, same "safe for innerHTML"
// contract, both surfaces. If you widen/narrow this escaping, make the
// matching edit there too (readability #H15, 20260904-frontend-arch-sweep).
export function escHtml(str) {
  return String(str ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// Proper three-way comparator for message-timestamp sorting (logic-errors
// #5, 20260904-frontend-arch-sweep) -- returns 0 for equal values instead of
// the `a > b ? 1 : -1` idiom this codebase used previously, which is not a
// valid Array#sort comparator (never returns 0) and can produce
// engine-dependent orderings for two equal-timestamp messages (e.g. an
// optimistic echo landing in the same instant as a history reload).
export function compareTimestamps(a, b) {
  const ta = a?.timestamp ?? '';
  const tb = b?.timestamp ?? '';
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
// mode (pre-8710a27a): back then, loadNotes/loadGroupNotes set state to the
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
  try {
    const [[bS, cS, vS], [bE, cE, vE]] = verses;
    if (!bS) return '';
    return (bS === bE && cS === cE && vS === vE)
      ? `${bS} ${cS}:${vS}`
      : `${bS} ${cS}:${vS} – ${bE} ${cE}:${vE}`;
  } catch {
    return '';
  }
}

// buildChapterHTML/versesToHTML/extractVerseNums below mirror
// frontend/js/bible.js's _buildHTML/_versesToHTML/_extractVerseNums -- same
// regex-based chapter-string tokenizer, independently maintained because the
// legacy tree has no shared build step with this app. Keep the two in sync by
// hand (readability #H14, 20260904-frontend-arch-sweep).
// Build HTML for a chapter string (verse spans, section heads)
export function buildChapterHTML(chStr) {
  let text = chStr.replace(/\[\d+\]/g, '');
  const parts = text.split('HEAD::');
  let html = '';
  parts.forEach((part, idx) => {
    if (!part.trim()) return;
    if (idx > 0) {
      const vIdx = Math.min(
        part.search(/\d+:\d/)                === -1 ? Infinity : part.search(/\d+:\d/),
        part.search(/(?<!\d)\d+(?=[A-Za-z])/) === -1 ? Infinity : part.search(/(?<!\d)\d+(?=[A-Za-z])/)
      );
      if (isFinite(vIdx) && vIdx > 0) {
        html += `<span class="section-head">${part.slice(0, vIdx).trim()}</span>`;
        html += versesToHTML(part.slice(vIdx));
      } else {
        html += `<span class="section-head">${part.trim()}</span>`;
      }
    } else {
      html += versesToHTML(part);
    }
  });
  return html;
}

function versesToHTML(text) {
  if (!text.trim()) return '';
  text = text.replace(/^\s*\d+:(\d+)\s*/, '[[V$1]]');
  text = text.replace(/(?<!\d)(\d+)(?=[A-Za-z])/g, '[[V$1]]');
  const tokens = text.split(/\[\[V(\d+)\]\]/);
  let html = '';
  if (tokens[0].trim()) html += tokens[0];
  for (let i = 1; i < tokens.length; i += 2) {
    const vNum  = tokens[i];
    const vText = tokens[i + 1] || '';
    html +=
      `<span class="verse-span" id="vs${vNum}">` +
      `<sup class="vnum" data-v="${vNum}">${vNum}</sup>` +
      ` ${vText}` +
      `</span>`;
  }
  return html;
}

export function extractVerseNums(chStr) {
  const text = chStr.replace(/\[\d+\]/g, '');
  const nums = new Set();
  const first = text.match(/^(\d+):(\d+)/);
  if (first) nums.add(parseInt(first[2]));
  const remaining = text.replace(/^\d+:\d+\s*/, '');
  const re = /(?<!\d)(\d+)(?=[A-Za-z])/g;
  let m;
  while ((m = re.exec(remaining)) !== null) {
    const n = parseInt(m[1]);
    if (n >= 1 && n <= 250) nums.add(n);
  }
  return [...nums].sort((a, b) => a - b);
}
