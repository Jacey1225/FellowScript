// Regression coverage for task 20260917-desktop-gif-image-render-bug's
// receive-side fix: image/GIF (and video) attachments rendered as a
// collapsed thin line specifically inside the packaged macOS Tauri/
// WKWebView desktop shell, while the identical frontend code rendered
// correctly on web/iOS.
//
// Root cause (see global.css's own comment above `.msg-bubble.msg-bubble-media`
// and `.attachment-gif-static`): `.attachment-media`'s `width: 100%` had no
// definite width to resolve against -- `.msg-bubble` (and, one layer deeper,
// the GIF static-preview `<button>`) had no width of its own, making it
// shrink-to-fit. WebKit's flex layout resolves that shrink-to-fit circular
// dependency to a near-zero cross size instead of the `<img>`'s intrinsic
// size (a long-standing WebKit flex bug); Chromium/Gecko resolve it
// correctly, which is exactly why this was desktop(WKWebView)-only despite
// byte-identical frontend code and CSS.
//
// jsdom does not run a real layout/flex engine, so the actual pixel collapse
// itself cannot be reproduced here. This file instead guards the two things
// that jsdom *can* prove and that a regression would actually break:
//   1. The DOM wiring that makes the CSS fix apply at all -- every media
//      attachment kind's bubble carries `.msg-bubble-media`, and the GIF
//      reduced-motion static-preview control carries `.attachment-gif-static`.
//   2. The fix's specific CSS declarations (explicit `width` breaking the
//      shrink-to-fit chain) are still present in global.css, rather than
//      relying on visual-only proof that will silently bit-rot if the rule
//      is edited or removed later without anyone noticing on web/iOS (where
//      the bug never reproduces).
//
// Run with: cd frontend && npm test -- --run src/components/ChatThread.attachmentMediaSizing.test.jsx
import React from 'react';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, test, expect, vi, beforeAll, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import ChatThread from './ChatThread.jsx';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const GLOBAL_CSS_PATH = path.resolve(__dirname, '../styles/global.css');

beforeAll(() => {
  if (!Element.prototype.scrollIntoView) {
    Element.prototype.scrollIntoView = () => {};
  }
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

const CONTACT = { id: 'c1', name: 'Ada Lovelace', type: 'friend' };
const USER = { user_id: 'u1', username: 'me' };

function renderThread(messages) {
  return render(
    <ChatThread
      contact={CONTACT}
      messages={messages}
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
    />
  );
}

describe('ChatThread — attachment bubble sizing (thin-line collapse regression)', () => {
  test('an image attachment bubble carries msg-bubble-media (the class the width fix targets)', () => {
    renderThread([{
      text: '', mine: false, sender: 'Ada', attachmentKind: 'image',
      attachmentUrl: 'https://example.com/photo.jpg', attachmentMeta: {},
    }]);
    const bubble = screen.getByAltText('photo attachment').closest('.msg-bubble');
    expect(bubble.className).toContain('msg-bubble-media');
  });

  test('a gif attachment bubble (motion allowed) carries msg-bubble-media', () => {
    renderThread([{
      text: '', mine: false, sender: 'Ada', attachmentKind: 'gif',
      attachmentUrl: 'https://example.com/g.gif',
      attachmentMeta: { url: 'https://example.com/g.gif' },
    }]);
    const bubble = screen.getByAltText('GIF attachment').closest('.msg-bubble');
    expect(bubble.className).toContain('msg-bubble-media');
  });

  test('a gif attachment bubble under reduced motion carries msg-bubble-media, and the static-preview control carries attachment-gif-static (the one-layer-deeper collapse site)', () => {
    const originalMatchMedia = window.matchMedia;
    window.matchMedia = (query) => ({
      matches: query.includes('prefers-reduced-motion'),
      media: query, onchange: null,
      addListener: () => {}, removeListener: () => {},
      addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => false,
    });
    try {
      renderThread([{
        text: '', mine: false, sender: 'Ada', attachmentKind: 'gif',
        attachmentUrl: 'https://example.com/g.gif',
        attachmentMeta: { url: 'https://example.com/g.gif', preview_url: 'https://example.com/g-static.gif' },
      }]);
      const tapToPlay = screen.getByLabelText('GIF attachment, tap to play');
      expect(tapToPlay.className).toContain('attachment-gif-static');
      const bubble = tapToPlay.closest('.msg-bubble');
      expect(bubble.className).toContain('msg-bubble-media');
    } finally {
      window.matchMedia = originalMatchMedia;
    }
  });

  test('a video attachment bubble carries msg-bubble-media', () => {
    renderThread([{
      text: '', mine: false, sender: 'Ada', attachmentKind: 'video',
      attachmentUrl: 'https://example.com/clip.mp4', attachmentMeta: {},
    }]);
    const playBtn = screen.getByLabelText('video attachment, tap to play');
    const bubble = playBtn.closest('.msg-bubble');
    expect(bubble.className).toContain('msg-bubble-media');
  });

  test('a text-only (non-media) bubble does NOT carry msg-bubble-media -- the fix is scoped to attachments, not every bubble', () => {
    renderThread([{ text: 'hello there', mine: false, sender: 'Ada' }]);
    const bubble = screen.getByText('hello there').closest('.msg-bubble');
    expect(bubble.className).not.toContain('msg-bubble-media');
  });
});

describe('ChatThread — .msg-bubble-media / .attachment-gif-static CSS still breaks the shrink-to-fit chain', () => {
  // Reads the actual shipped stylesheet rather than a computed style (jsdom
  // has no flex/layout engine, so getComputedStyle can't reproduce the
  // WebKit-specific collapse this guards against) -- this asserts the
  // specific declarations task 20260917-desktop-gif-image-render-bug added,
  // so a future edit that drops them regresses loudly here instead of only
  // on a real desktop-app visual check.
  const css = fs.readFileSync(GLOBAL_CSS_PATH, 'utf8');

  function ruleBodyFor(literalSelector) {
    // Matches "<selector> {" (a literal, unescaped CSS selector as it
    // appears in the file, e.g. ".msg-bubble.msg-bubble-media") through to
    // its closing brace.
    const escaped = literalSelector.replace(/[.]/g, '\\.');
    const match = css.match(new RegExp(`${escaped}\\s*\\{([^}]*)\\}`));
    return match ? match[1] : null;
  }

  test('.msg-bubble.msg-bubble-media has an explicit width (the fix -- gives .attachment-media\'s width:100% a definite basis)', () => {
    const body = ruleBodyFor('.msg-bubble.msg-bubble-media');
    expect(body).not.toBeNull();
    expect(body).toMatch(/width:\s*220px/);
  });

  test('.attachment-gif-static has an explicit display:block + width:100% (the one-layer-deeper fix for the reduced-motion static-preview button)', () => {
    const body = ruleBodyFor('.attachment-gif-static');
    expect(body).not.toBeNull();
    expect(body).toMatch(/display:\s*block/);
    expect(body).toMatch(/width:\s*100%/);
  });

  test('.attachment-media itself still has no explicit height (relies on the ancestor width, not a hardcoded aspect box, for its sizing)', () => {
    const body = ruleBodyFor('.attachment-media');
    expect(body).not.toBeNull();
    const declarations = body.split(';').map((d) => d.trim()).filter(Boolean);
    const hasBareHeight = declarations.some((d) => /^height:/.test(d));
    expect(hasBareHeight).toBe(false);
    expect(body).toMatch(/max-height:/);
  });
});
