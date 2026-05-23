// Bible data, navigation state, and chapter rendering.
// Does NOT import highlights — reader.js wires applyHighlights via setChapterRenderedCallback.

export let bible      = null;
export let curBook    = null;
export let curChapter = null;

const bookSel   = document.getElementById('book-sel');
const chSel     = document.getElementById('ch-sel');
export const vsSel = document.getElementById('vs-sel');
const stateLoad = document.getElementById('state-loading');
const stateWelc = document.getElementById('state-welcome');
const card      = document.getElementById('chapter-card');
const cardLabel = document.getElementById('card-book-label');
const cardTitle = document.getElementById('card-title');
const cardHead  = document.getElementById('card-section-head');
const cardBody  = document.getElementById('card-body');
const cardLoc   = document.getElementById('card-loc');
const prevBtn   = document.getElementById('prev-btn');
const nextBtn   = document.getElementById('next-btn');

let _onChapterRendered = () => {};

export function setChapterRenderedCallback(fn) {
  _onChapterRendered = fn;
}

// Single-chapter books store their content in entry[0] (no separate heading entry).
// Multi-chapter books store a heading in entry[0] and chapters in entry[1..n].
function _getChapters(book) {
  const entries = bible[book];
  return entries.length === 1 ? entries : entries.slice(1);
}

// ── Load ────────────────────────────────────────────────────────────────────

export async function loadBible() {
  try {
    const res = await fetch('../data/bible.json');
    if (!res.ok) throw new Error(res.status);
    bible = await res.json();

    Object.keys(bible).forEach(book => {
      const o = document.createElement('option');
      o.value = o.textContent = book;
      bookSel.appendChild(o);
    });

    stateLoad.style.display = 'none';
    stateWelc.style.display = 'block';
    return true;
  } catch {
    stateLoad.innerHTML =
      '<p style="color:rgba(200,134,26,0.65);font-size:.8rem;letter-spacing:.15em;text-transform:uppercase">' +
      'Could not load scripture data.</p>';
    return false;
  }
}

// ── Navigation ──────────────────────────────────────────────────────────────

export function applyHash() {
  const h = location.hash.slice(1);
  if (!h || !bible) return;
  const parts = h.split('-');
  if (parts.length < 2) return;
  const book = parts[0].replace(/_/g, ' ');
  const ch   = parseInt(parts[1]);
  const vs   = parts[2] ? parseInt(parts[2]) : null;
  if (bible[book] && ch >= 1) {
    setBook(book);
    setChapter(ch);
    if (vs) setVerse(vs);
  }
}

export function pushHash(book, ch, vs) {
  const b = book.replace(/ /g, '_');
  location.hash = vs ? `${b}-${ch}-${vs}` : `${b}-${ch}`;
}

export function setBook(book) {
  if (!bible[book]) return;
  curBook    = book;
  curChapter = null;
  bookSel.value = book;

  const chapters = _getChapters(book);
  chSel.innerHTML = '<option value="">— Chapter —</option>';
  chapters.forEach((_, i) => {
    const o = document.createElement('option');
    o.value = i + 1;
    o.textContent = `Chapter ${i + 1}`;
    chSel.appendChild(o);
  });
  chSel.disabled = false;

  vsSel.innerHTML = '<option value="">—</option>';
  vsSel.disabled  = true;

  stateWelc.style.display = 'block';
  card.style.display      = 'none';
}

export function setChapter(chNum) {
  if (!curBook) return;
  const chapters = _getChapters(curBook);
  if (chNum < 1 || chNum > chapters.length) return;

  curChapter = chNum;
  chSel.value = chNum;

  const chStr = chapters[chNum - 1];
  _renderCard(chStr, chNum);
  _populateVerses(chStr);

  prevBtn.disabled = chNum <= 1;
  nextBtn.disabled = chNum >= chapters.length;
  cardLoc.textContent = `${curBook}  ·  ${chNum}`;

  stateWelc.style.display = 'none';
  card.style.display      = 'block';
  card.style.animation    = 'none';
  requestAnimationFrame(() => { card.style.animation = ''; });
  card.scrollIntoView({ behavior: 'smooth', block: 'start' });

  _onChapterRendered();
}

export function setVerse(vNum) {
  if (!curBook || !curChapter) return;
  vsSel.value = vNum;
  document.querySelectorAll('.verse-span.active').forEach(el => el.classList.remove('active'));
  const span = document.getElementById(`vs${vNum}`);
  if (span) {
    span.classList.add('active');
    span.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }
  pushHash(curBook, curChapter, vNum);
}

// ── Verse selector population ───────────────────────────────────────────────

function _populateVerses(chStr) {
  const nums = _extractVerseNums(chStr);
  vsSel.innerHTML = '<option value="">— Verse —</option>';
  nums.forEach(n => {
    const o = document.createElement('option');
    o.value = n;
    o.textContent = `Verse ${n}`;
    vsSel.appendChild(o);
  });
  vsSel.disabled = nums.length === 0;
}

function _extractVerseNums(chStr) {
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

// ── Rendering ───────────────────────────────────────────────────────────────

function _renderCard(chStr, chNum) {
  // Single-chapter books have no separate heading entry; skip preamble extraction.
  const isSingle = bible[curBook].length === 1;
  const preamble = isSingle ? '' : (bible[curBook][0] || '').replace('HEAD::', '').trim();
  cardLabel.textContent = curBook.toUpperCase();
  cardTitle.textContent = `Chapter ${chNum}`;
  cardHead.textContent  = chNum === 1 && preamble ? preamble : '';
  cardBody.innerHTML    = _buildHTML(chStr);
}

function _buildHTML(chStr) {
  let text = chStr.replace(/\[\d+\]/g, '');
  const parts = text.split('HEAD::');
  let html = '';

  parts.forEach((part, idx) => {
    if (!part.trim()) return;
    if (idx > 0) {
      const vIdx = Math.min(
        part.search(/\d+:\d/)           === -1 ? Infinity : part.search(/\d+:\d/),
        part.search(/(?<!\d)\d+(?=[A-Za-z])/) === -1 ? Infinity : part.search(/(?<!\d)\d+(?=[A-Za-z])/)
      );
      if (isFinite(vIdx) && vIdx > 0) {
        html += `<span class="section-head">${part.slice(0, vIdx).trim()}</span>`;
        html += _versesToHTML(part.slice(vIdx));
      } else {
        html += `<span class="section-head">${part.trim()}</span>`;
      }
    } else {
      html += _versesToHTML(part);
    }
  });

  return html;
}

function _versesToHTML(text) {
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

// ── Selector events ─────────────────────────────────────────────────────────

export function initBibleEvents() {
  bookSel.addEventListener('change', () => {
    if (bookSel.value) { setBook(bookSel.value); pushHash(bookSel.value, 1, null); }
  });

  chSel.addEventListener('change', () => {
    if (chSel.value) { setChapter(parseInt(chSel.value)); pushHash(curBook, curChapter, null); }
  });

  vsSel.addEventListener('change', () => {
    if (vsSel.value) setVerse(parseInt(vsSel.value));
  });

  prevBtn.addEventListener('click', () => {
    if (curChapter > 1) { setChapter(curChapter - 1); pushHash(curBook, curChapter, null); }
  });

  nextBtn.addEventListener('click', () => {
    const total = _getChapters(curBook).length;
    if (curChapter < total) { setChapter(curChapter + 1); pushHash(curBook, curChapter, null); }
  });
}
