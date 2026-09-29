// Task 20260929-announcement-banner-crop-list-style testing: layout regression
// for the widget clipping bug (title / "View" pushed out of frame by an
// oversized aspect-fill image) and the Notes-card list row. jsdom does no
// layout, so this asserts the DOM stacking order plus the actual shipped CSS
// rules from global.css.
// Run: cd frontend && npx vitest run src/components/AnnouncementBannerLayout.test.jsx
import React from 'react';
import fs from 'node:fs';
import path from 'node:path';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor } from '@testing-library/react';

vi.mock('../lib/announcementsApi.js', async () => {
  const actual = await vi.importActual('../lib/announcementsApi.js');
  return { ...actual, ANNOUNCEMENTS_ENABLED: true, fetchLatestAnnouncement: vi.fn(), fetchAnnouncements: vi.fn() };
});
import * as api from '../lib/announcementsApi.js';
import GroupAnnouncementWidget, { _clearWidgetCache } from './GroupAnnouncementWidget.jsx';
import GroupAnnouncements, { _clearAnnouncementCaches } from './GroupAnnouncements.jsx';

const css = fs.readFileSync(path.resolve(__dirname, '../styles/global.css'), 'utf8');
// Declaration block for an exact selector list entry (first match).
function rule(selector) {
  const esc = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const m = css.match(new RegExp(`(?:^|\\n|\\})\\s*${esc}\\s*\\{([^}]*)\\}`));
  if (!m) throw new Error(`no CSS rule for ${selector}`);
  return m[1];
}
const has = (block, decl) => expect(block.replace(/\s+/g, ' ')).toContain(decl);

function installStorage() {
  const m = new Map();
  Object.defineProperty(window, 'localStorage', { configurable: true, value: {
    getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)),
    removeItem: k => m.delete(k), clear: () => m.clear() } });
}
beforeEach(() => { _clearWidgetCache(); _clearAnnouncementCaches(); installStorage(); Object.values(api).forEach(f => f.mockReset?.()); });
afterEach(cleanup);

const mk = (id, extra = {}) => ({ id, title: `Title ${id}`, description: `Body ${id}`, banner_url: 'https://cdn.example/tall.jpg',
  publish_at: '2026-01-01T00:00:00Z', published: true, can_edit: true, creator_username: 'ann', ...extra });

describe('widget: title and View render inside the clipped 3:1 frame with a scrim', () => {
  // Same DOM for a tall (portrait) and a bright (white) photo: the fix is
  // structural, independent of the image pixels.
  for (const [label, url] of [['tall photo', 'https://cdn.example/tall-4000x9000.jpg'], ['white photo', 'https://cdn.example/white.jpg']]) {
    test(`${label}: image, scrim, then text/View are children of the one clipped card`, async () => {
      api.fetchLatestAnnouncement.mockResolvedValue({ announcement: mk('a', { banner_url: url }) });
      const { container } = render(<GroupAnnouncementWidget userId="u1" groupId="g1" />);
      const card = await screen.findByRole('button', { name: /Announcement: Title a/ });
      const kids = Array.from(card.children).map(c => c.className);
      const iImg = kids.findIndex(c => c.includes('announce-widget-img'));
      const iScrim = kids.findIndex(c => c.includes('announce-widget-scrim'));
      const iText = kids.findIndex(c => c.includes('announce-widget-text'));
      // paint order: image < scrim < text and View (later siblings paint on top)
      expect(iImg).toBeGreaterThanOrEqual(0);
      expect(iImg).toBeLessThan(iScrim);
      expect(iScrim).toBeLessThan(iText);
      // the old "View" chip is gone: the whole card is the tap target
      expect(kids.some(c => c.includes('announce-widget-cta'))).toBe(false);
      expect(card.textContent).toContain('ANNOUNCEMENT');
      expect(card.textContent).toContain('Title a');
      expect(card.textContent).not.toContain('View');
      expect(container.querySelector('img.announce-widget-img').getAttribute('src')).toBe(url);
      // dismiss stays a sibling outside the clipped card
      expect(card.contains(screen.getByLabelText('Dismiss announcement'))).toBe(false);
    });
  }

  test('CSS: widget box is 3:1, card fills it and clips, image is out-of-flow cover so it cannot grow the box', () => {
    has(rule('.announce-widget'), 'aspect-ratio: 3 / 1');
    expect(rule('.announce-widget')).not.toMatch(/(^|;|\s)height:\s*72px/);
    const card = rule('.announce-widget-card');
    has(card, 'position: absolute'); has(card, 'inset: 0'); has(card, 'overflow: hidden');
    const img = rule('.announce-widget-img');
    has(img, 'position: absolute'); has(img, 'inset: 0'); has(img, 'width: 100%'); has(img, 'height: 100%'); has(img, 'object-fit: cover');
  });

  test('CSS: scrim is dark under the text (bottom stops >= 0.72 alpha) and text is light', () => {
    const scrim = rule('.announce-widget-scrim');
    has(scrim, 'position: absolute'); has(scrim, 'inset: 0');
    const alphas = [...scrim.matchAll(/rgba\(0,\s*0,\s*0,\s*([\d.]+)\)\s*(\d+)%/g)].map(m => [parseFloat(m[1]), parseInt(m[2], 10)]);
    const bottom = alphas.filter(([, pos]) => pos <= 40);
    expect(bottom.length).toBeGreaterThan(0);
    bottom.forEach(([a]) => expect(a).toBeGreaterThanOrEqual(0.72));
    has(rule('.announce-widget-title'), 'color: #F2F2F2');
    has(rule('.announce-widget-title'), 'text-shadow');
  });

  test('WCAG AA: parchment text over the minimum scrim alpha on a pure white photo is >= 4.5:1', () => {
    const lum = (v) => { const c = v / 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
    const L = (r, g, b) => 0.2126 * lum(r) + 0.7152 * lum(g) + 0.0722 * lum(b);
    const alpha = 0.72; // scrim alpha behind the text block
    const bg = 255 * (1 - alpha);        // white photo composited under black scrim
    const ratio = (L(242, 242, 242) + 0.05) / (L(bg, bg, bg) + 0.05);
    expect(ratio).toBeGreaterThanOrEqual(4.5);
  });
});

describe('list row: Notes card treatment + 3:1 banner strip', () => {
  test('row is card-bg with a --card-border hairline, radius-md, Notes body padding; swipe clip container kept', () => {
    const row = rule('.group-info-announcements-row');
    has(row, 'background: var(--card-bg)'); has(row, 'border: 1px solid var(--card-border)'); has(row, 'border-radius: var(--radius-md)');
    has(rule('.group-info-announcements-open'), 'padding: 0.85rem 0.95rem'); // == .note-card .ant-card-body
    has(rule('.group-info-announcements-item'), 'overflow: hidden');
    has(rule('.group-info-announcements-item'), 'border-radius: var(--radius-md)');
    has(rule('.group-info-announcements-row-swiped'), 'translateX(88px)');
    has(rule('.group-info-announcements-swipe-delete'), 'min-height: 44px');
    has(rule('.group-info-announcements-thumb'), 'aspect-ratio: 3 / 1');
    has(rule('.group-info-announcements-thumb'), 'object-fit: cover');
    // the same tokens the Notes card uses
    expect(rule('.note-card.ant-card')).toContain('var(--card-bg)');
    expect(rule('.note-card.ant-card')).toContain('var(--radius-md)');
  });

  test('viewer, form preview and banner button all use the same 3:1 cover/center box (legacy banners cover-fit)', () => {
    for (const sel of ['.group-info-announcements-banner-preview', '.group-info-announcements-banner']) has(rule(sel), 'aspect-ratio: 3 / 1');
    for (const sel of ['.group-info-announcements-banner-preview img', '.group-info-announcements-banner img']) {
      has(rule(sel), 'object-fit: cover'); has(rule(sel), 'object-position: center');
    }
  });

  test('renders banner thumb before the text inside the open button; no thumb when no banner; swipe delete + kebab intact', async () => {
    api.fetchAnnouncements.mockResolvedValue({ announcements: [mk('a'), mk('b', { banner_url: null })], gate: null, truncated: false });
    const { container } = render(<GroupAnnouncements userId="u1" groupId="g1" onBack={vi.fn()} onGroupGone={vi.fn()} onUpgrade={vi.fn()} />);
    await screen.findByText('Title a');
    const items = container.querySelectorAll('li.group-info-announcements-item');
    expect(items.length).toBe(2);
    const openA = items[0].querySelector('button.group-info-announcements-open');
    expect(openA.firstElementChild.tagName).toBe('IMG');
    expect(openA.firstElementChild.className).toContain('group-info-announcements-thumb');
    expect(items[1].querySelector('img.group-info-announcements-thumb')).toBeNull();
    expect(screen.getByLabelText('More actions for Title a')).toBeTruthy();
  });
});
