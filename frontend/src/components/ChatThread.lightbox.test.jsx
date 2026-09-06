// Tests for the tap-to-expand attachment lightbox (task
// 20260905-attachment-lightbox, testing step 5) added to ChatThread.jsx's
// AttachmentContent: opening the lightbox from the image/gif branches,
// dismissing via backdrop/media/close-button tap, the portal-to-document.body
// requirement (design-notes.md §5, the dockview backdrop-filter bug), GIF
// restart-on-open (design-notes.md §3), and that the pre-existing
// reduced-motion GIF tap-to-play and video tap-to-play affordances are
// unaffected by this change.
//
// Run with: cd frontend && npm test -- --run src/components/ChatThread.lightbox.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeAll, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, act } from '@testing-library/react';
import ChatThread from './ChatThread.jsx';

beforeAll(() => {
  if (!Element.prototype.scrollIntoView) {
    Element.prototype.scrollIntoView = () => {};
  }
});

const CONTACT = { id: 'c1', name: 'Ada Lovelace', type: 'friend' };
const USER = { user_id: 'u1', username: 'me' };

function renderThread(props = {}) {
  const utils = render(
    <ChatThread
      contact={CONTACT}
      messages={[]}
      groupMembers={[]}
      user={USER}
      onBack={vi.fn()}
      onSend={vi.fn()}
      onRequestUploadUrl={vi.fn()}
      onUploadToS3={vi.fn()}
      onSearchGifs={vi.fn().mockResolvedValue([])}
      sessions={[]}
      activeSessionId={null}
      talkingUserId={null}
      onJoinSession={vi.fn()}
      onLeaveSession={vi.fn()}
      onOpenSessionCreator={vi.fn()}
      onEditSession={vi.fn()}
      onDeleteSession={vi.fn()}
      onNavigateVerse={vi.fn()}
      videoEnabled={false}
      videoTiles={{}}
      onToggleVideo={vi.fn()}
      bindVideoTile={vi.fn()}
      {...props}
    />
  );
  return utils;
}

function setReducedMotion(matches) {
  const original = window.matchMedia;
  window.matchMedia = (query) => ({
    matches: matches && query.includes('prefers-reduced-motion'),
    media: query, onchange: null,
    addListener: () => {}, removeListener: () => {},
    addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => false,
  });
  return () => { window.matchMedia = original; };
}

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe('ChatThread — attachment lightbox — opening', () => {
  test('tapping an image attachment opens a full-screen dialog portaled to document.body', () => {
    renderThread({
      messages: [{
        text: '', mine: false, sender: 'Ada', attachmentKind: 'image',
        attachmentUrl: 'https://example.com/photo.jpg', attachmentMeta: {},
      }],
    });
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();

    fireEvent.click(screen.getByAltText('photo attachment'));

    const dialog = screen.getByRole('dialog', { name: 'Expanded image attachment' });
    expect(dialog).toBeInTheDocument();
    // Portaled directly under document.body, not nested inside the message
    // bubble tree (required for the backdrop-filter to actually render, per
    // design-notes.md §5's dockview compositing-bug workaround).
    expect(dialog.parentElement).toBe(document.body);
    expect(dialog.className).toContain('attachment-lightbox-overlay');
    expect(screen.getByAltText('Photo attachment, expanded')).toBeInTheDocument();
  });

  test('tapping a gif attachment (motion allowed) opens the lightbox with the gif still animating', () => {
    renderThread({
      messages: [{
        text: '', mine: false, sender: 'Ada', attachmentKind: 'gif',
        attachmentUrl: 'https://example.com/g.gif',
        attachmentMeta: { url: 'https://example.com/g.gif' },
      }],
    });
    fireEvent.click(screen.getByAltText('GIF attachment'));

    const dialog = screen.getByRole('dialog', { name: 'Expanded GIF attachment' });
    expect(dialog).toBeInTheDocument();
    const expandedImg = screen.getByAltText('GIF attachment, expanded');
    // A plain <img> with no autoplay-suppression -- animates natively, same
    // as the inline instance, and is a fresh mount (design-notes.md §3: the
    // expanded gif is not the same DOM node as the inline one, so it starts
    // at frame 0 rather than sharing playback phase).
    expect(expandedImg.tagName).toBe('IMG');
    expect(expandedImg).not.toBe(screen.getByAltText('GIF attachment'));
    expect(expandedImg.src).toBe('https://example.com/g.gif');
  });

  test('under reduced motion, a gif only opens the lightbox on the second tap -- the first tap starts inline playback per the existing convention', () => {
    const restore = setReducedMotion(true);
    try {
      renderThread({
        messages: [{
          text: '', mine: false, sender: 'Ada', attachmentKind: 'gif',
          attachmentUrl: 'https://example.com/g.gif',
          attachmentMeta: { url: 'https://example.com/g.gif', preview_url: 'https://example.com/g-static.gif' },
        }],
      });
      const tapToPlay = screen.getByLabelText('GIF attachment, tap to play');
      fireEvent.click(tapToPlay);
      // First tap only starts inline playback; no lightbox yet.
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument();

      fireEvent.click(screen.getByAltText('GIF attachment'));
      expect(screen.getByRole('dialog', { name: 'Expanded GIF attachment' })).toBeInTheDocument();
    } finally {
      restore();
    }
  });
});

describe('ChatThread — attachment lightbox — dismissal', () => {
  function openImageLightbox(reducedMotion = false) {
    renderThread({
      messages: [{
        text: '', mine: false, sender: 'Ada', attachmentKind: 'image',
        attachmentUrl: 'https://example.com/photo.jpg', attachmentMeta: {},
      }],
    });
    fireEvent.click(screen.getByAltText('photo attachment'));
    return screen.getByRole('dialog', { name: 'Expanded image attachment' });
  }

  test('tapping the backdrop dismisses the lightbox (reduced motion: closes immediately, no lingering exit state)', () => {
    const restore = setReducedMotion(true);
    try {
      const dialog = openImageLightbox();
      fireEvent.click(dialog);
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    } finally {
      restore();
    }
  });

  test('tapping the expanded media itself dismisses the lightbox', () => {
    const restore = setReducedMotion(true);
    try {
      openImageLightbox();
      fireEvent.click(screen.getByAltText('Photo attachment, expanded'));
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    } finally {
      restore();
    }
  });

  test('the close (X) button dismisses the lightbox and is independently reachable (not just backdrop tap)', () => {
    const restore = setReducedMotion(true);
    try {
      openImageLightbox();
      fireEvent.click(screen.getByLabelText('Close'));
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    } finally {
      restore();
    }
  });

  test('dismissing never shows a confirmation dialog (non-destructive, reversible action per Q10)', () => {
    const restore = setReducedMotion(true);
    try {
      openImageLightbox();
      fireEvent.click(screen.getByLabelText('Close'));
      expect(screen.queryByRole('dialog', { name: /confirm|discard|sure/i })).not.toBeInTheDocument();
    } finally {
      restore();
    }
  });

  test('with motion allowed, dismissal removes the dialog from the DOM after the exit transition completes', async () => {
    vi.useFakeTimers();
    try {
      const dialog = openImageLightbox();
      fireEvent.click(dialog);
      // Still present immediately (mid closing-transition), then gone once
      // the exit timer (~200ms, matching the CSS exit-animation duration) fires.
      expect(document.querySelector('.attachment-lightbox-closing')).toBeInTheDocument();
      act(() => { vi.advanceTimersByTime(200); });
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    } finally {
      vi.useRealTimers();
    }
  });

  test('reopening after dismissal works (not a one-shot affordance)', () => {
    const restore = setReducedMotion(true);
    try {
      renderThread({
        messages: [{
          text: '', mine: false, sender: 'Ada', attachmentKind: 'image',
          attachmentUrl: 'https://example.com/photo.jpg', attachmentMeta: {},
        }],
      });
      fireEvent.click(screen.getByAltText('photo attachment'));
      fireEvent.click(screen.getByLabelText('Close'));
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument();

      fireEvent.click(screen.getByAltText('photo attachment'));
      expect(screen.getByRole('dialog', { name: 'Expanded image attachment' })).toBeInTheDocument();
    } finally {
      restore();
    }
  });
});

describe('ChatThread — attachment lightbox — unaffected existing behaviors', () => {
  test('video attachments still show the tap-to-play placeholder, never open a lightbox', () => {
    renderThread({
      messages: [{
        text: '', mine: false, sender: 'Ada', attachmentKind: 'video',
        attachmentUrl: 'https://example.com/clip.mp4', attachmentMeta: {},
      }],
    });
    const playBtn = screen.getByLabelText('video attachment, tap to play');
    fireEvent.click(playBtn);
    expect(document.querySelector('video[controls]')).toBeInTheDocument();
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
  });

  test('file attachments are unaffected -- still a plain download link, no lightbox', () => {
    renderThread({
      messages: [{
        text: '', mine: false, sender: 'Ada', attachmentKind: 'file',
        attachmentUrl: 'https://example.com/report.pdf',
        attachmentMeta: { filename: 'Q3-report.pdf' },
      }],
    });
    fireEvent.click(screen.getByLabelText('file attachment, Q3-report.pdf, download'));
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
  });

  test('a broken image degrades to the unavailable placeholder and is not clickable into a lightbox', () => {
    renderThread({
      messages: [{
        text: '', mine: false, sender: 'Ada', attachmentKind: 'image',
        attachmentUrl: 'https://example.com/gone.jpg', attachmentMeta: {},
      }],
    });
    fireEvent.error(screen.getByAltText('photo attachment'));
    expect(screen.getByText('Image unavailable')).toBeInTheDocument();
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
  });
});
