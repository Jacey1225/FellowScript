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
import { checkAndResumeTour } from './tour.js';

// ── Theme toggle ─────────────────────────────────────────────────────────────

(function () {
  const btn  = document.getElementById('theme-toggle');
  const html = document.documentElement;
  const SUN  = `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="4.5"/><line x1="12" y1="2"    x2="12" y2="5"/><line x1="12" y1="19"   x2="12" y2="22"/><line x1="2"  y1="12"   x2="5"  y2="12"/><line x1="19" y1="12"   x2="22" y2="12"/><line x1="4.93" y1="4.93"  x2="6.93" y2="6.93"/><line x1="17.07" y1="17.07" x2="19.07" y2="19.07"/><line x1="19.07" y1="4.93"  x2="17.07" y2="6.93"/><line x1="6.93"  y1="17.07" x2="4.93" y2="19.07"/></svg>`;
  const MOON = `<svg width="16" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>`;
  const sync = () => { btn.innerHTML = html.classList.contains('light-mode') ? MOON : SUN; };
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

window.addEventListener('hashchange', () => {
  applyHash();
  localStorage.setItem('last_page', location.hash.slice(1));
});

// ── "Messages" button in notes header (desktop + mobile) ──────────────────────

document.getElementById('sidebar-open-msgs-btn')?.addEventListener('click', () => {
  // On mobile, ensure notes sidebar is open so messages slides over it
  if (window.innerWidth <= 640) {
    const notesSb = document.getElementById('notes-sidebar');
    if (!notesSb.classList.contains('open')) {
      notesSb.classList.add('open');
      document.body.classList.add('sidebar-open');
    }
  }
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

  if (!location.hash) {
    const lastPage = localStorage.getItem('last_page');
    location.hash = lastPage ? `#${lastPage}` : '#Genesis-1';
    return; // hashchange fires applyHash + saves last_page
  }

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
checkAndResumeTour();
