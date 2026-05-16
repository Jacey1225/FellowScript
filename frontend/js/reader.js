// Entry point — imports all modules, wires global events, runs init().

import { user }  from './config.js';
import {
  loadBible, applyHash, setVerse,
  setChapterRenderedCallback, initBibleEvents,
} from './bible.js';
import {
  loadHighlights, applyHighlights,
  openHlPicker, closeHlPicker, initHighlightPicker,
} from './highlights.js';
import {
  loadNotes, populateGroupSelector,
  initNotesSidebar, initSidebarResize,
} from './notes.js';
import {
  msgWs, loadContactList, connectWS, initMessaging,
} from './messaging.js';

// ── Theme toggle ─────────────────────────────────────────────────────────────

(function () {
  const btn  = document.getElementById('theme-toggle');
  const html = document.documentElement;
  const sync = () => { btn.textContent = html.classList.contains('light-mode') ? '☽' : '☀'; };
  sync();
  btn.addEventListener('click', () => {
    html.classList.toggle('light-mode');
    localStorage.setItem('theme', html.classList.contains('light-mode') ? 'light' : 'dark');
    sync();
  });
})();

// ── Nav account link ─────────────────────────────────────────────────────────

(function () {
  const label = !user ? 'Sign In' : (user.username || 'Account');
  const href  = !user ? 'signin.html' : 'account.html';
  const nav   = document.getElementById('nav-account');
  const drawer = document.getElementById('drawer-account');
  if (nav)    { nav.textContent    = label; nav.href    = href; }
  if (drawer) { drawer.textContent = label; drawer.href = href; }
})();

// ── Hamburger menu ────────────────────────────────────────────────────────────

(function () {
  const hamburger = document.getElementById('hamburger');
  const drawer    = document.getElementById('mobile-nav-drawer');
  if (!hamburger || !drawer) return;
  hamburger.addEventListener('click', () => {
    const open = hamburger.classList.toggle('open');
    drawer.classList.toggle('open', open);
  });
  document.addEventListener('click', e => {
    if (!hamburger.contains(e.target) && !drawer.contains(e.target)) {
      hamburger.classList.remove('open');
      drawer.classList.remove('open');
    }
  });
})();

// ── Verse click → highlight picker ───────────────────────────────────────────

document.addEventListener('click', e => {
  if (e.target.closest('#hl-picker')) return;
  const span = e.target.closest('.verse-span');
  if (span && span.id.startsWith('vs')) {
    const vNum = parseInt(span.id.slice(2));
    setVerse(vNum);
    openHlPicker(span, vNum);
    e.stopPropagation();
    return;
  }
  closeHlPicker();
});

window.addEventListener('hashchange', applyHash);

// ── Desktop "Messages" button in notes header ─────────────────────────────────

document.getElementById('sidebar-open-msgs-btn')?.addEventListener('click', () => {
  document.getElementById('msg-sidebar').classList.add('open');
  document.body.classList.add('msg-open');
  if (user) { loadContactList(); if (!msgWs || msgWs.readyState > 1) connectWS(); }
});

// ── Mobile bottom tab bar ─────────────────────────────────────────────────────

function _wireMobileTabs() {
  const mobileMsgBtn   = document.getElementById('mobile-msg-btn');
  const mobileNotesBtn = document.getElementById('mobile-notes-btn');
  if (!mobileMsgBtn || !mobileNotesBtn) return;

  mobileMsgBtn.addEventListener('click', () => {
    const msgSb   = document.getElementById('msg-sidebar');
    const notesSb = document.getElementById('notes-sidebar');
    const isOpen  = msgSb.classList.contains('open');
    if (notesSb.classList.contains('open')) {
      notesSb.classList.remove('open');
      document.body.classList.remove('sidebar-open');
      mobileNotesBtn.classList.remove('active');
    }
    msgSb.classList.toggle('open', !isOpen);
    document.body.classList.toggle('msg-open', !isOpen);
    mobileMsgBtn.classList.toggle('active', !isOpen);
    if (!isOpen && user) {
      loadContactList();
      if (!msgWs || msgWs.readyState > 1) connectWS();
    }
  });

  mobileNotesBtn.addEventListener('click', () => {
    const notesSb = document.getElementById('notes-sidebar');
    const msgSb   = document.getElementById('msg-sidebar');
    const isOpen  = notesSb.classList.contains('open');
    if (msgSb.classList.contains('open')) {
      msgSb.classList.remove('open');
      document.body.classList.remove('msg-open');
      mobileMsgBtn.classList.remove('active');
    }
    notesSb.classList.toggle('open', !isOpen);
    document.body.classList.toggle('sidebar-open', !isOpen);
    mobileNotesBtn.classList.toggle('active', !isOpen);
    if (!isOpen && user) { loadNotes(); populateGroupSelector(); }
  });
}

// ── Init ──────────────────────────────────────────────────────────────────────

async function init() {
  const ok = await loadBible();
  if (!ok) return;

  // Desktop: notes sidebar always visible
  if (window.innerWidth >= 641) {
    document.getElementById('notes-sidebar').classList.add('open');
    document.body.classList.add('sidebar-open');
    if (user) { loadNotes(); populateGroupSelector(); }
  }

  await loadHighlights();
  applyHash();
}

// Wire everything up, then boot
setChapterRenderedCallback(applyHighlights);
initHighlightPicker();
initNotesSidebar();
initSidebarResize();
initMessaging();
initBibleEvents();
_wireMobileTabs();
init();
