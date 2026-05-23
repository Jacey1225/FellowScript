// Interactive onboarding tour powered by Driver.js v1.
// Triggered by new-user signup or the "Tour" button on the homepage.
// Tour state is stored in localStorage so it survives cross-page navigation.

import { driver } from 'https://cdn.jsdelivr.net/npm/driver.js@1.3.1/+esm';

const TOUR_KEY = 'fs_tour';

function clearTour() { localStorage.removeItem(TOUR_KEY); }

function openSidebar(sidebarId, toggleId) {
  const sidebar = document.getElementById(sidebarId);
  if (sidebar && !sidebar.classList.contains('open')) {
    document.getElementById(toggleId)?.click();
  }
}

function closeSidebar(sidebarId, toggleId) {
  const sidebar = document.getElementById(sidebarId);
  if (sidebar?.classList.contains('open')) {
    document.getElementById(toggleId)?.click();
  }
}

// ── Index page tour ───────────────────────────────────────────────────────────
// Two steps: welcome intro + CTA that navigates to the reader.

export function startIndexTour() {
  localStorage.setItem(TOUR_KEY, 'reader');

  const d = driver({
    showProgress:  false,
    popoverClass:  'fs-tour',
    allowClose:    true,
    onCloseClick:  () => { clearTour(); d.destroy(); },
    steps: [
      {
        popover: {
          title:       'Welcome to FellowScript',
          description: 'This quick tour walks you through the whole platform — Bible reading, personal highlights, study notes, community features, and messaging. It only takes a minute.',
          nextBtnText: "Let's go!",
        },
      },
      {
        element:     '.hero-cta',
        popover: {
          title:       'Head to the Reader',
          description: 'Everything starts on the Read page. Click next and we\'ll take you there.',
          side:        'top',
          align:       'center',
          nextBtnText: 'Open the Reader →',
          onNextClick: () => { window.location.href = 'reader.html'; },
        },
      },
    ],
  });

  d.drive();
}

// ── Reader page tour ──────────────────────────────────────────────────────────

export function startReaderTour() {
  // Pre-open the notes sidebar so its child elements are in position.
  openSidebar('notes-sidebar', 'sidebar-toggle');

  // Allow the sidebar slide-in animation to settle before the tour starts.
  setTimeout(() => {
    const d = driver({
      showProgress:  true,
      popoverClass:  'fs-tour',
      allowClose:    true,
      onCloseClick:  () => { clearTour(); d.destroy(); },
      steps: [

        // ── Overview ────────────────────────────────────────────────────────
        {
          popover: {
            title:       'The Reading Experience',
            description: 'The <strong>left side</strong> is your Bible study space — navigate passages, read chapters, and highlight verses. The <strong>right side</strong> is your community hub — study notes and messages with friends and groups.',
          },
        },

        // ── Bible navigation ────────────────────────────────────────────────
        {
          element: '.scripture-nav',
          popover: {
            title:       'Scripture Navigation',
            description: 'These three selectors let you jump to any passage in the entire Bible.',
            side:        'bottom',
            align:       'center',
          },
        },
        {
          element: '#book-sel',
          popover: {
            title:       '① Choose a Book',
            description: 'Select any of the 66 books — from Genesis all the way through Revelation.',
            side:        'bottom',
            align:       'start',
          },
        },
        {
          element: '#ch-sel',
          popover: {
            title:       '② Select a Chapter',
            description: 'Once a book is selected, choose the chapter you want to read.',
            side:        'bottom',
            align:       'center',
          },
        },
        {
          element: '#vs-sel',
          popover: {
            title:       '③ Jump to a Verse',
            description: 'Optionally scroll straight to a specific verse within the chapter.',
            side:        'bottom',
            align:       'end',
          },
        },

        // ── Reading area ────────────────────────────────────────────────────
        {
          element: '#state-welcome',
          popover: {
            title:       'Reading Area',
            description: 'Your selected passage appears here. Use the <strong>← Previous</strong> and <strong>Next →</strong> buttons to move between chapters without touching the dropdowns.',
            side:        'right',
            align:       'center',
          },
        },

        // ── Highlights ──────────────────────────────────────────────────────
        {
          popover: {
            title:       'Highlight Verses',
            description: 'After loading a chapter, <strong>click and drag to select any verse text</strong>. A colour picker appears — choose a colour to save a personal highlight. Your highlights persist across sessions. When in a group, you\'ll also see your fellow members\' highlights in softer shades.',
          },
        },

        // ── Notes sidebar ───────────────────────────────────────────────────
        {
          element: '#sidebar-toggle',
          popover: {
            title:       'Study Notes Panel',
            description: 'This button opens and closes your Notes panel. All your personal and shared study notes live here.',
            side:        'left',
            align:       'center',
          },
          onHighlightStarted: () => openSidebar('notes-sidebar', 'sidebar-toggle'),
        },
        {
          element: '#new-note-btn',
          popover: {
            title:       'Create a Note',
            description: 'Tap <strong>+ New</strong> to write a study note. You can link it to a specific Bible passage by filling in the verse range fields inside the form.',
            side:        'bottom',
            align:       'end',
          },
          onHighlightStarted: () => openSidebar('notes-sidebar', 'sidebar-toggle'),
        },
        {
          element: '.stabs',
          popover: {
            title:       'Note Tabs',
            description: '<strong>Notes</strong> — all your personal study notes, including those anchored to a scripture passage.<br><strong>Public</strong> — notes shared with members of your active study group.',
            side:        'bottom',
            align:       'center',
          },
          onHighlightStarted: () => openSidebar('notes-sidebar', 'sidebar-toggle'),
        },

        // ── Groups + public notes ───────────────────────────────────────────
        {
          element: '#group-sel',
          popover: {
            title:       'Study Groups',
            description: 'Select a group here to enter its shared workspace. Public notes from all group members appear on the <strong>Public</strong> tab. When writing a note, check <em>Visible to group</em> to share it with everyone in the group.',
            side:        'bottom',
            align:       'start',
          },
          onHighlightStarted: () => openSidebar('notes-sidebar', 'sidebar-toggle'),
        },

        // ── Filter ──────────────────────────────────────────────────────────
        {
          element: '#sidebar-open-filter-btn',
          popover: {
            title:       'Filter & Sort Notes',
            description: 'Click this icon to filter notes by book, title, date, or group member — and sort them newest-first or oldest-first.',
            side:        'bottom',
            align:       'start',
          },
          onHighlightStarted: () => openSidebar('notes-sidebar', 'sidebar-toggle'),
        },

        // ── Switch to messages ──────────────────────────────────────────────
        {
          element: '#sidebar-open-msgs-btn',
          popover: {
            title:       'Open Messages',
            description: 'Click here to switch from Notes to the Messages panel, where you can chat with friends and study groups in real time.',
            side:        'bottom',
            align:       'end',
          },
          onHighlightStarted: () => openSidebar('notes-sidebar', 'sidebar-toggle'),
        },
        {
          element: '#msg-sidebar',
          popover: {
            title:       'Messages Panel',
            description: 'All your direct messages and group chats live here. Select any conversation to open it and start chatting.',
            side:        'left',
            align:       'center',
          },
          onHighlightStarted: () => {
            closeSidebar('notes-sidebar', 'sidebar-toggle');
            openSidebar('msg-sidebar', 'msg-toggle');
          },
        },
        {
          element: '#msg-add-friend-btn',
          popover: {
            title:       'Add Friends',
            description: 'Click <strong>+ Add</strong> and enter someone\'s username to send a friend request. Once they accept, you can message each other and invite them to study groups.',
            side:        'bottom',
            align:       'start',
          },
          onHighlightStarted: () => openSidebar('msg-sidebar', 'msg-toggle'),
        },
        {
          element: '#msg-new-group-btn',
          popover: {
            title:       'Create a Study Group',
            description: 'Click <strong>+ New</strong> to start a group with your friends. Groups unlock a shared Public notes tab, group highlights, and a dedicated group chat.',
            side:        'bottom',
            align:       'start',
          },
          onHighlightStarted: () => openSidebar('msg-sidebar', 'msg-toggle'),
        },

        // ── Navigate to Account ─────────────────────────────────────────────
        {
          element: '#nav-account',
          popover: {
            title:       'Your Account',
            description: 'One last stop — your Account page where you can manage your profile, view your activity stats, and respond to friend requests.',
            side:        'bottom',
            align:       'end',
            nextBtnText: 'Go to Account →',
            onNextClick: () => {
              localStorage.setItem(TOUR_KEY, 'account');
              window.location.href = 'account.html';
            },
          },
          onHighlightStarted: () => closeSidebar('msg-sidebar', 'msg-toggle'),
        },
      ],
    });

    d.drive();
  }, 400);
}

// ── Account page tour ─────────────────────────────────────────────────────────

export function startAccountTour() {
  setTimeout(() => {
    const d = driver({
      showProgress:  true,
      popoverClass:  'fs-tour',
      allowClose:    true,
      onCloseClick:  () => { clearTour(); d.destroy(); },
      steps: [
        {
          popover: {
            title:       'Your Account',
            description: 'This is your profile page. Here you can view your activity, respond to friend requests, and update your account settings.',
          },
        },
        {
          element: '#stats-row',
          popover: {
            title:       'Activity Stats',
            description: 'A quick snapshot of your community engagement — Friends, Groups, Notes written, and Verses highlighted.',
            side:        'bottom',
            align:       'center',
          },
        },
        {
          element: '#requests-list',
          popover: {
            title:       'Friend Requests',
            description: 'Incoming friend requests appear here. Accept them to connect — you\'ll be able to message each other directly and form study groups together.',
            side:        'top',
            align:       'center',
          },
        },
        {
          element: '#edit-form',
          popover: {
            title:       'Edit Your Profile',
            description: 'Update your display name, email address, or password here at any time.',
            side:        'top',
            align:       'center',
          },
        },
        {
          popover: {
            title:       "You're All Set! 🎉",
            description: 'You now know everything you need to get the most out of FellowScript. Open the Word, take notes, and connect with your community!',
            nextBtnText: 'Back to Reading →',
            onNextClick: () => {
              clearTour();
              window.location.href = 'reader.html';
            },
          },
        },
      ],
    });

    d.drive();
  }, 300);
}

// ── Auto-resume on page load ──────────────────────────────────────────────────
// Called by each page on init to continue a tour after cross-page navigation.

export function checkAndResumeTour() {
  const phase = localStorage.getItem(TOUR_KEY);
  if (!phase) return;

  const path = window.location.pathname;

  if (phase === 'reader' && path.includes('reader')) {
    startReaderTour();
  } else if (phase === 'account' && path.includes('account')) {
    startAccountTour();
  }
}
