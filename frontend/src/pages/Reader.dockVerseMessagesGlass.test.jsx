// Regression test for the glass-verse-selector-messages fix
// (.claude/pipeline/20260826-glass-verse-selector-messages): the Bible
// verse-selector dropdown (.bib-nav-widget, shared by VerseSelector.jsx and
// BibleNavigator.jsx, both createPortal'd to document.body) and the Messages
// panel (.chat-overlay in MessagingPanel.jsx, .msg-bubble in ChatThread.jsx)
// still used the pre-glassmorphism opaque-dark `--widget-bg` / flat-fill
// treatment the rest of the dockable-tabs UI had already migrated off of.
//
// This is a source-guard test (same pattern as Reader.dockGlassFix.test.jsx
// and Reader.dockGlassAudit.test.jsx), since jsdom doesn't implement
// backdrop-filter compositing well enough to assert the actual composited
// look. Live-render verification (computed styles + screenshots via headless
// Chromium, in both light and dark theme) was done separately and is
// recorded in this task's testing.json, not here.
//
// Run with: cd frontend && npm test -- --run src/pages/Reader.dockVerseMessagesGlass.test.jsx
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { describe, test, expect } from 'vitest';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function readStripped(relPath) {
  const raw = fs.readFileSync(path.join(__dirname, relPath), 'utf8');
  return raw.replace(/\/\*[\s\S]*?\*\//g, '');
}

describe('global.css — .bib-nav-widget (verse-selector dropdown) glass restyle', () => {
  test('.bib-nav-widget no longer uses the opaque --widget-bg fill, and instead uses literal warm-glass values matching the .notes-group-select-dropdown document.body-portal precedent', () => {
    const css = readStripped('../styles/global.css');
    const match = css.match(/\.bib-nav-widget\s*\{([^}]*)\}/);
    expect(match, 'expected a .bib-nav-widget rule').toBeTruthy();
    const body = match[1];
    expect(body).not.toMatch(/background:\s*var\(--widget-bg\)/);
    expect(body).toMatch(/background:\s*rgba\(32,24,17,0\.6\)/);
    expect(body).toMatch(/backdrop-filter:\s*blur\(16px\)\s*saturate\(160%\)/);
    expect(body).toMatch(/border:\s*1px solid rgba\(237,230,214,0\.10\)/);
    expect(body).toMatch(/box-shadow:\s*0 8px 24px rgba\(0,0,0,0\.35\)/);
  });

  test('.bib-nav-widget pins book/chapter text tokens to their light-on-dark values (always-dark glass surface, not theme-swapped)', () => {
    const css = readStripped('../styles/global.css');
    const match = css.match(/\.bib-nav-widget\s*\{([^}]*)\}/);
    expect(match, 'expected a .bib-nav-widget rule').toBeTruthy();
    const body = match[1];
    expect(body).toMatch(/--bib-book-text:\s*rgba\(242,242,242,0\.6\)/);
    expect(body).toMatch(/--bib-ch-text:\s*rgba\(242,242,242,0\.55\)/);
  });

  test('[data-theme="light"] hover-state overrides on .bib-book-btn/.bib-ch-btn are neutralized within .bib-nav-widget (dark-ink hover text would be illegible against the now always-dark glass)', () => {
    const css = readStripped('../styles/global.css');
    expect(css).toMatch(/\[data-theme="light"\] \.bib-nav-widget \.bib-book-btn:hover\s*\{[^}]*color:\s*var\(--parchment\)/);
    expect(css).toMatch(/\[data-theme="light"\] \.bib-nav-widget \.bib-ch-btn:hover\s*\{[^}]*color:\s*var\(--parchment\)/);
  });

  test('the notes-group-select-dropdown precedent in reader-dock.css uses the same literal glass values (confirms visual consistency, not just source-level accident)', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.notes-group-select-dropdown\.ant-select-dropdown\s*\{([^}]*)\}/);
    expect(match, 'expected a .notes-group-select-dropdown.ant-select-dropdown rule').toBeTruthy();
    expect(match[1]).toMatch(/background:\s*rgba\(32,24,17,0\.6\)/);
    expect(match[1]).toMatch(/backdrop-filter:\s*blur\(16px\)\s*saturate\(160%\)/);
  });
});

describe('global.css — .chat-overlay (Messages panel background) glass restyle', () => {
  test('.chat-overlay no longer uses the near-opaque rgba(8,5,2,0.99) flat fill, and instead uses a lighter warm translucent fill+blur than its already-glass .dv-groupview ancestor', () => {
    const css = readStripped('../styles/global.css');
    const match = css.match(/\.chat-overlay\s*\{([^}]*)\}/);
    expect(match, 'expected a .chat-overlay rule').toBeTruthy();
    const body = match[1];
    expect(body).not.toMatch(/rgba\(8,5,2,0\.99\)/);
    expect(body).toMatch(/background:\s*rgba\(20,14,9,0\.4\)/);
    expect(body).toMatch(/backdrop-filter:\s*blur\(10px\)\s*saturate\(150%\)/);
  });

  test('.chat-overlay blur (10px) is lighter than its .dv-groupview panel ancestor blur (16px), per the "nested glass gets a lighter blur than its parent" rule', () => {
    const cssDock = readStripped('../styles/reader-dock.css');
    expect(cssDock).toMatch(/--panel-glass-blur:\s*16px/);
    const cssGlobal = readStripped('../styles/global.css');
    const match = cssGlobal.match(/\.chat-overlay\s*\{([^}]*)\}/);
    expect(match[1]).toMatch(/backdrop-filter:\s*blur\(10px\)/);
  });
});

describe('global.css — .msg-bubble frosted-glass restyle', () => {
  test('.msg-bubble has its own (lightest-in-chain) backdrop-filter blur, distinct from the flat solid-fill it replaced', () => {
    const css = readStripped('../styles/global.css');
    const match = css.match(/\n\.msg-bubble\s*\{([^}]*)\}/);
    expect(match, 'expected a .msg-bubble rule').toBeTruthy();
    expect(match[1]).toMatch(/backdrop-filter:\s*blur\(6px\)\s*saturate\(140%\)/);
  });

  test('.msg-bubble.sent / .msg-bubble.received keep translucent (not flat-opaque) fills with a hairline border, at slightly bumped opacity for legibility against the now-translucent .chat-overlay backdrop', () => {
    const css = readStripped('../styles/global.css');
    const sent = css.match(/\.msg-bubble\.sent\s*\{([^}]*)\}/);
    const received = css.match(/\.msg-bubble\.received\s*\{([^}]*)\}/);
    expect(sent, 'expected a .msg-bubble.sent rule').toBeTruthy();
    expect(received, 'expected a .msg-bubble.received rule').toBeTruthy();
    expect(sent[1]).toMatch(/background:\s*rgba\(255,198,26,0\.22\)/);
    expect(sent[1]).toMatch(/border:\s*1px solid rgba\(255,198,26,0\.22\)/);
    expect(received[1]).toMatch(/background:\s*rgba\(237,230,214,0\.08\)/);
    expect(received[1]).toMatch(/border:\s*1px solid var\(--border-glass\)/);
    expect(received[1]).toMatch(/color:\s*rgba\(242,242,242,0\.8\)/);
  });

  test('bubble blur (6px) is lighter than .chat-overlay (10px), which is lighter than .dv-groupview (16px) -- full nesting chain holds', () => {
    const css = readStripped('../styles/global.css');
    const bubble = css.match(/\n\.msg-bubble\s*\{([^}]*)\}/)[1];
    const overlay = css.match(/\.chat-overlay\s*\{([^}]*)\}/)[1];
    const bubbleBlur = parseInt(bubble.match(/backdrop-filter:\s*blur\((\d+)px\)/)[1], 10);
    const overlayBlur = parseInt(overlay.match(/backdrop-filter:\s*blur\((\d+)px\)/)[1], 10);
    const cssDock = readStripped('../styles/reader-dock.css');
    const panelBlur = parseInt(cssDock.match(/--panel-glass-blur:\s*(\d+)px/)[1], 10);
    expect(bubbleBlur).toBeLessThan(overlayBlur);
    expect(overlayBlur).toBeLessThan(panelBlur);
  });
});

describe('VerseSelector.jsx / MessagingPanel.jsx / ChatThread.jsx — no structural/functional changes', () => {
  test('VerseSelector.jsx still portals .bib-nav-widget to document.body and preserves book -> chapter -> verse selection flow (desktop 3-column + mobile step-by-step)', () => {
    const src = fs.readFileSync(path.join(__dirname, '../components/VerseSelector.jsx'), 'utf8');
    expect(src).toMatch(/createPortal\(/);
    expect(src).toMatch(/document\.body/);
    expect(src).toMatch(/className="bib-nav-widget verse-sel-widget"/);
    expect(src).toMatch(/bib-nav-books/);
    expect(src).toMatch(/bib-nav-chapters/);
    expect(src).toMatch(/bib-nav-verses/);
    expect(src).toMatch(/handleVerseSelect/);
  });

  test('MessagingPanel.jsx still wraps ChatThread in .chat-overlay only when a contact is selected', () => {
    const src = fs.readFileSync(path.join(__dirname, '../components/panels/MessagingPanel.jsx'), 'utf8');
    expect(src).toMatch(/currentContact &&/);
    expect(src).toMatch(/className="chat-overlay"/);
    expect(src).toMatch(/<ChatThread/);
  });

  test('ChatThread.jsx still renders messages with the sent/received bubble split and a working send handler', () => {
    const src = fs.readFileSync(path.join(__dirname, '../components/ChatThread.jsx'), 'utf8');
    expect(src).toMatch(/msg-bubble \$\{m\.mine \? 'sent' : 'received'\}/);
    expect(src).toMatch(/handleSend/);
    expect(src).toMatch(/onSend/);
  });
});
