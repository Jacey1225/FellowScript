// Highlight picker UI, applying highlights, and shared group state.
// Owns currentGroupId, groupNotes, groupHighlights, groupUsernames.

import { API, user }    from './config.js';
import { hexWithAlpha } from './utils.js';
import { curBook, curChapter } from './bible.js';

const hlPicker = document.getElementById('hl-picker');

// ── Shared group state (owned here, read by notes.js and reader.js via live bindings) ──

export let currentGroupId  = null;
export let groupNotes      = {};
export let groupHighlights = {};
export let groupUsernames  = {};
export let localHl         = {};

let hlTargetV = null;

export function setCurrentGroupId(id)              { currentGroupId  = id; }
export function setGroupNotes(notes)               { groupNotes      = notes; }
export function setGroupHighlightData(hl, unames)  { groupHighlights = hl; groupUsernames = unames; }

// ── Load / apply ────────────────────────────────────────────────────────────

export async function loadHighlights() {
  if (!user) return;
  try {
    const res = await fetch(`${API}/notes/highlight/${user.user_id}`);
    if (res.ok) localHl = await res.json();
  } catch { /* offline */ }
}

export function applyHighlights() {
  document.querySelectorAll('.verse-span').forEach(el => {
    el.removeAttribute('data-hl');
    el.style.background = '';
    el.querySelectorAll('.hl-badge').forEach(b => b.remove());
  });

  Object.entries(localHl).forEach(([key, color]) => {
    const [book, ch, vs] = key.split('-');
    if (book === curBook && parseInt(ch) === curChapter) {
      const span = document.getElementById(`vs${vs}`);
      if (span) {
        span.dataset.hl      = color;
        span.style.background = hexWithAlpha(color, 0.28);
      }
    }
  });

  if (currentGroupId) {
    Object.entries(groupHighlights).forEach(([uid, highlights]) => {
      const uname   = groupUsernames[uid] || uid.slice(0, 3);
      const initial = uname[0].toUpperCase();
      Object.entries(highlights).forEach(([key, color]) => {
        const [book, ch, vs] = key.split('-');
        if (book === curBook && parseInt(ch) === curChapter) {
          const span = document.getElementById(`vs${vs}`);
          if (span) {
            if (!span.dataset.hl) span.style.background = hexWithAlpha(color, 0.2);
            const badge = document.createElement('span');
            badge.className        = 'hl-badge';
            badge.title            = uname;
            badge.style.background = color;
            badge.textContent      = initial;
            span.appendChild(badge);
          }
        }
      });
    });
  }
}

// ── Picker open / close ─────────────────────────────────────────────────────

export function openHlPicker(anchorEl, vNum) {
  hlTargetV = vNum;
  const rect = anchorEl.getBoundingClientRect();
  hlPicker.style.left = `${rect.left}px`;
  hlPicker.style.top  = `${rect.bottom + 6}px`;
  hlPicker.classList.add('visible');
  requestAnimationFrame(() => {
    const maxLeft = window.innerWidth - hlPicker.offsetWidth - 8;
    hlPicker.style.left = `${Math.max(8, Math.min(rect.left, maxLeft))}px`;
  });
}

export function closeHlPicker() {
  hlPicker.classList.remove('visible');
  hlTargetV = null;
}

// ── Picker swatch / clear events ────────────────────────────────────────────

export function initHighlightPicker() {
  hlPicker.querySelectorAll('.hl-swatch').forEach(swatch => {
    swatch.addEventListener('click', async e => {
      e.stopPropagation();
      if (!user || !hlTargetV || !curBook || !curChapter) return;
      const color    = swatch.dataset.color;
      const verseNum = hlTargetV;
      const key      = `${curBook}-${curChapter}-${verseNum}`;
      localHl[key]   = color;
      applyHighlights();
      closeHlPicker();
      try {
        await fetch(`${API}/notes/highlight/${user.user_id}`, {
          method:  'POST',
          headers: { 'Content-Type': 'application/json' },
          body:    JSON.stringify({ book: curBook, chapter: curChapter, verse: verseNum, color }),
        });
      } catch { /* offline */ }
    });
  });

  hlPicker.querySelector('.hl-clear').addEventListener('click', async e => {
    e.stopPropagation();
    if (!user || !hlTargetV || !curBook || !curChapter) return;
    const key = `${curBook}-${curChapter}-${hlTargetV}`;
    delete localHl[key];
    applyHighlights();
    closeHlPicker();
    try {
      await fetch(`${API}/notes/highlight/${user.user_id}/${encodeURIComponent(key)}`, {
        method: 'DELETE',
      });
    } catch { /* offline */ }
  });
}
