// Task 20260929-announcement-title-color-crop-layer-fix testing: form flow,
// title_color rendering in widget/list/viewer, cropper clipping, and Post/Save
// gating while the banner upload is in flight.
// Run: cd frontend && npx vitest run src/components/AnnouncementTitleColorFlow.test.jsx
import React from 'react';
import fs from 'node:fs';
import path from 'node:path';
import { describe, test, expect, vi, beforeEach, afterEach, beforeAll } from 'vitest';
import { render, screen, fireEvent, cleanup, waitFor, act } from '@testing-library/react';

vi.mock('../lib/announcementsApi.js', async () => {
  const actual = await vi.importActual('../lib/announcementsApi.js');
  return {
    ...actual, ANNOUNCEMENTS_ENABLED: true,
    fetchAnnouncements: vi.fn(), createAnnouncement: vi.fn(), updateAnnouncement: vi.fn(),
    deleteAnnouncement: vi.fn(), uploadAnnouncementBanner: vi.fn(), fetchLatestAnnouncement: vi.fn(),
  };
});
vi.mock('../lib/cropBanner.js', async () => {
  const actual = await vi.importActual('../lib/cropBanner.js');
  return { ...actual, resolveCropSource: vi.fn(), cropToFile: vi.fn() };
});
vi.mock('../lib/groupInfoApi.js', () => ({
  fetchGroupInfo: vi.fn(), renameGroup: vi.fn(), setGroupMuted: vi.fn(),
  uploadGroupPhoto: vi.fn(), removeGroupPhoto: vi.fn(), confirmGroupPhoto: vi.fn(), fetchGroupGallery: vi.fn(),
  GROUP_PHOTO_LIMITS: { maxBytes: 15 * 1024 * 1024, accept: ['image/png'], oversizeCopy: 'x' },
}));
import * as api from '../lib/announcementsApi.js';
import * as infoApi from '../lib/groupInfoApi.js';
import * as crop from '../lib/cropBanner.js';
import GroupAnnouncements, { _clearAnnouncementCaches } from './GroupAnnouncements.jsx';
import GroupAnnouncementViewer from './GroupAnnouncementViewer.jsx';
import GroupAnnouncementWidget, { _clearWidgetCache } from './GroupAnnouncementWidget.jsx';
import BannerCropper from './BannerCropper.jsx';
import { _clearGroupInfoCaches } from './GroupInfoPanel.jsx';

beforeAll(() => { if (!Element.prototype.scrollIntoView) Element.prototype.scrollIntoView = () => {}; });

const mk = (id, extra = {}) => ({
  id, title: `Title ${id}`, description: `Body ${id}`, banner_url: null, publish_at: '2026-01-01T00:00:00Z',
  published: true, can_edit: true, creator_username: 'ann', ...extra,
});
const list = (announcements) => ({ announcements, gate: null, truncated: false });
const mount = () => render(<GroupAnnouncements userId="u1" groupId="g1" onBack={vi.fn()} onGroupGone={vi.fn()} onUpgrade={vi.fn()} />);

beforeEach(() => {
  _clearAnnouncementCaches(); _clearGroupInfoCaches(); _clearWidgetCache();
  Object.values(api).forEach(f => f.mockReset?.());
  Object.values(infoApi).forEach(f => f.mockReset?.());
  crop.resolveCropSource.mockReset(); crop.cropToFile.mockReset();
  infoApi.fetchGroupInfo.mockResolvedValue({ title: 'G', photo_url: null, muted: false });
  infoApi.fetchGroupGallery.mockResolvedValue({ items: [], has_more: false });
  const m = new Map();
  Object.defineProperty(window, 'localStorage', { configurable: true, value: {
    getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k), clear: () => m.clear() } });
});
afterEach(cleanup);

const openCreate = async () => {
  api.fetchAnnouncements.mockResolvedValue(list([]));
  mount();
  await screen.findByText('No announcements yet.');
  fireEvent.click(await screen.findByLabelText('New announcement'));
  await screen.findByText('New announcement', { selector: 'h3' });
  fireEvent.change(screen.getByLabelText('Title'), { target: { value: 'Hi' } });
  fireEvent.change(screen.getByLabelText('Message'), { target: { value: 'There' } });
};
const openEdit = async (item) => {
  api.fetchAnnouncements.mockResolvedValue(list([item]));
  mount();
  await screen.findByText(item.title);
  fireEvent.click(screen.getByLabelText(`More actions for ${item.title}`));
  fireEvent.click(screen.getByText('Edit'));
  await screen.findByText('Edit announcement');
};

describe('form flow: title_color sent only when changed', () => {
  test('create with default color omits title_color', async () => {
    api.createAnnouncement.mockResolvedValue(mk('n'));
    await openCreate();
    fireEvent.click(screen.getByText('Post'));
    await waitFor(() => expect(api.createAnnouncement).toHaveBeenCalled());
    expect('title_color' in api.createAnnouncement.mock.calls[0][2]).toBe(false);
  });

  test('create with a swatch sends the uppercase hex and preview reflects it', async () => {
    api.createAnnouncement.mockResolvedValue(mk('n'));
    await openCreate();
    fireEvent.click(screen.getByRole('radio', { name: 'Sky' }));
    const title = document.querySelector('.title-color-preview .announce-widget-title');
    expect(title.textContent).toBe('Hi');
    expect(title.style.getPropertyValue('--title-color')).toBe('#9CD3FF');
    expect(screen.getByRole('img', { name: 'Preview of the announcement title in Sky' })).toBeTruthy();
    fireEvent.click(screen.getByText('Post'));
    await waitFor(() => expect(api.createAnnouncement).toHaveBeenCalled());
    expect(api.createAnnouncement.mock.calls[0][2].title_color).toBe('#9CD3FF');
  });

  test('create with custom lowercase color is sent uppercase', async () => {
    api.createAnnouncement.mockResolvedValue(mk('n'));
    await openCreate();
    fireEvent.change(screen.getByLabelText('Custom color'), { target: { value: '#123abc' } });
    fireEvent.click(screen.getByText('Post'));
    await waitFor(() => expect(api.createAnnouncement).toHaveBeenCalled());
    expect(api.createAnnouncement.mock.calls[0][2].title_color).toBe('#123ABC');
  });

  test('edit without touching color does not send title_color', async () => {
    api.updateAnnouncement.mockResolvedValue(mk('a'));
    await openEdit(mk('a', { title_color: '#FFC61A' }));
    expect(screen.getByRole('radio', { name: 'Gold' })).toHaveAttribute('aria-checked', 'true');
    fireEvent.change(screen.getByLabelText('Title'), { target: { value: 'Changed' } });
    fireEvent.click(screen.getByText('Save'));
    await waitFor(() => expect(api.updateAnnouncement).toHaveBeenCalled());
    expect(api.updateAnnouncement.mock.calls[0][3]).toEqual({ title: 'Changed', description: 'Body a' });
  });

  test('edit: changing color sends only that change', async () => {
    api.updateAnnouncement.mockResolvedValue(mk('a'));
    await openEdit(mk('a', { title_color: '#FFC61A' }));
    fireEvent.click(screen.getByRole('radio', { name: 'Mint' }));
    fireEvent.click(screen.getByText('Save'));
    await waitFor(() => expect(api.updateAnnouncement).toHaveBeenCalled());
    expect(api.updateAnnouncement.mock.calls[0][3]).toEqual({ title: 'Title a', description: 'Body a', title_color: '#9BE7B4' });
  });

  test('edit: Reset to default sends explicit null', async () => {
    api.updateAnnouncement.mockResolvedValue(mk('a'));
    await openEdit(mk('a', { title_color: '#FFC61A' }));
    fireEvent.click(screen.getByText('Reset to default'));
    fireEvent.click(screen.getByText('Save'));
    await waitFor(() => expect(api.updateAnnouncement).toHaveBeenCalled());
    expect(api.updateAnnouncement.mock.calls[0][3].title_color).toBeNull();
  });

  test('edit: selecting default on an unset announcement sends nothing; invalid stored color is treated as default (not resent)', async () => {
    api.updateAnnouncement.mockResolvedValue(mk('a'));
    await openEdit(mk('a', { title_color: 'red; background:url(x)' }));
    expect(screen.getByRole('radio', { name: 'Parchment (default)' })).toHaveAttribute('aria-checked', 'true');
    fireEvent.change(screen.getByLabelText('Title'), { target: { value: 'C' } });
    fireEvent.click(screen.getByText('Save'));
    await waitFor(() => expect(api.updateAnnouncement).toHaveBeenCalled());
    expect('title_color' in api.updateAnnouncement.mock.calls[0][3]).toBe(false);
  });

  test('low-contrast custom color warns but does not block Post', async () => {
    await openCreate();
    fireEvent.change(screen.getByLabelText('Custom color'), { target: { value: '#222222' } });
    expect(screen.getByRole('status').textContent).toMatch(/hard to read/);
    expect(screen.getByText('Post').closest('button')).not.toBeDisabled();
  });
});

describe('Post/Save disabled while the banner upload is in flight', () => {
  async function cropAndDone() {
    crop.resolveCropSource.mockResolvedValue({ objectUrl: 'blob:src', name: 'a.png' });
    crop.cropToFile.mockResolvedValue(new File(['c'], 'a.jpg', { type: 'image/jpeg' }));
    fireEvent.change(screen.getByTestId('announcement-banner-input'), { target: { files: [new File(['x'], 'a.png', { type: 'image/png' })] } });
    const dialog = await screen.findByRole('dialog', { name: 'Crop banner' });
    const img = await waitFor(() => { const i = dialog.querySelector('img.banner-cropper-img'); if (!i) throw new Error('img'); return i; });
    Object.defineProperty(img, 'naturalWidth', { configurable: true, value: 4000 });
    Object.defineProperty(img, 'naturalHeight', { configurable: true, value: 3000 });
    fireEvent.load(img);
    await waitFor(() => expect(screen.getByText('Done')).not.toBeDisabled());
    fireEvent.click(screen.getByText('Done'));
  }

  test('create: Post is disabled ("Uploading...") until the upload resolves, then sends the fresh key', async () => {
    let resolve;
    api.uploadAnnouncementBanner.mockReturnValue(new Promise(r => { resolve = r; }));
    api.createAnnouncement.mockResolvedValue(mk('n'));
    await openCreate();
    await cropAndDone();
    await waitFor(() => expect(screen.queryByRole('dialog', { name: 'Crop banner' })).toBeNull());
    const btn = screen.getByText('Uploading…').closest('button');
    expect(btn).toBeDisabled();
    fireEvent.click(btn);
    expect(api.createAnnouncement).not.toHaveBeenCalled();
    await act(async () => { resolve('group-announcements/g1/new'); });
    await waitFor(() => expect(screen.getByText('Post').closest('button')).not.toBeDisabled());
    fireEvent.click(screen.getByText('Post'));
    await waitFor(() => expect(api.createAnnouncement).toHaveBeenCalled());
    expect(api.createAnnouncement.mock.calls[0][2].banner_key).toBe('group-announcements/g1/new');
  });

  test('edit: Save is disabled mid-upload; a failed upload re-enables Save without a stale banner_key', async () => {
    let reject;
    api.uploadAnnouncementBanner.mockReturnValue(new Promise((_, r) => { reject = r; }));
    api.updateAnnouncement.mockResolvedValue(mk('a'));
    await openEdit(mk('a'));
    await cropAndDone();
    await waitFor(() => expect(screen.getByText('Uploading…').closest('button')).toBeDisabled());
    await act(async () => { reject(Object.assign(new Error('nope'), { status: 0 })); });
    await screen.findByRole('alert');
    const save = await screen.findByText('Save');
    expect(save.closest('button')).not.toBeDisabled();
    fireEvent.click(save);
    await waitFor(() => expect(api.updateAnnouncement).toHaveBeenCalled());
    expect('banner_key' in api.updateAnnouncement.mock.calls[0][3]).toBe(false);
  });
});

describe('title_color rendering', () => {
  test('widget: validated color via --title-color; default and injection strings fall back to F2F2F2', async () => {
    api.fetchLatestAnnouncement.mockResolvedValue({ announcement: mk('a', { title_color: '#9cd3ff', banner_url: 'https://x/b.png' }) });
    const { container, unmount } = render(<GroupAnnouncementWidget userId="u1" groupId="g1" />);
    await screen.findByText('Title a');
    const t = () => container.querySelector('.announce-widget-title');
    expect(t().style.getPropertyValue('--title-color')).toBe('#9CD3FF');
    unmount(); _clearWidgetCache();
    for (const bad of [null, undefined, 'red; background:url(x)', '#FFF']) {
      api.fetchLatestAnnouncement.mockResolvedValue({ announcement: mk('b', { title_color: bad }) });
      const r = render(<GroupAnnouncementWidget userId="u1" groupId="g1" />);
      await screen.findByText('Title b');
      expect(r.container.querySelector('.announce-widget-title').style.getPropertyValue('--title-color')).toBe('#F2F2F2');
      r.unmount(); _clearWidgetCache();
    }
  });

  test('list row: AA color applied on dark surface; default/invalid/failing inherit', async () => {
    api.fetchAnnouncements.mockResolvedValue(list([
      mk('a', { title_color: '#9CD3FF' }), mk('b', { title_color: null }), mk('c', { title_color: 'x;y' }), mk('d', { title_color: '#222222' }),
    ]));
    mount();
    await screen.findByText('Title a');
    const c = (t) => screen.getByText(t).style.color;
    expect(c('Title a')).toMatch(/rgb\(156, 211, 255\)|#9cd3ff/i);
    expect(c('Title b')).toBe('');
    expect(c('Title c')).toBe('');
    expect(c('Title d')).toBe('');
  });

  test('viewer: applies color, tolerates missing title_color', () => {
    const { rerender } = render(<GroupAnnouncementViewer item={mk('a', { title_color: '#9CD3FF' })} onBack={vi.fn()} />);
    expect(screen.getByRole('heading', { name: 'Title a' }).style.color).toMatch(/rgb\(156, 211, 255\)|#9cd3ff/i);
    rerender(<GroupAnnouncementViewer item={mk('a')} onBack={vi.fn()} />);
    expect(screen.getByRole('heading', { name: 'Title a' }).style.color).toBe('');
  });
});

describe('web cropper clipping and opaque bars', () => {
  const css = fs.readFileSync(path.resolve(__dirname, '../styles/global.css'), 'utf8');
  const rule = (sel) => { const m = css.match(new RegExp(`(^|\\n)${sel.replace(/[.]/g, '\\.')}\\s*\\{([^}]*)\\}`)); return m ? m[2] : ''; };

  test('frame and stage clip overflow; mask cannot capture pointer events', () => {
    expect(rule('.banner-cropper-frame')).toMatch(/overflow:\s*hidden/);
    expect(css).toMatch(/\.banner-cropper-stage\s*\{\s*overflow:\s*hidden/);
    expect(rule('.banner-cropper-mask')).toMatch(/pointer-events:\s*none/);
    expect(rule('.banner-cropper-img')).toMatch(/pointer-events:\s*none/);
    expect(rule('.banner-cropper')).toMatch(/overflow:\s*hidden/);
  });

  test('header bar and controls sit above the stage with opaque background and safe-area padding', () => {
    expect(rule('.banner-cropper-bar')).toMatch(/z-index:\s*2/);
    expect(rule('.banner-cropper-bar')).toMatch(/background:\s*#0d0d0d/);
    expect(rule('.banner-cropper-bar')).toMatch(/env\(safe-area-inset-top\)/);
    expect(css).toMatch(/\.banner-cropper-controls\s*\{[^}]*\}/);
    expect(css).toMatch(/\.banner-cropper-error,\s*\.banner-cropper-help,\s*\.banner-cropper-controls\s*\{[^}]*z-index:\s*2[^}]*background:\s*#0d0d0d/);
  });

  test('DOM: image lives inside the clipping frame; bar/controls are outside the stage', async () => {
    crop.resolveCropSource.mockResolvedValue({ objectUrl: 'blob:x', name: 'p.png' });
    const { container } = render(<BannerCropper source={{ file: new File(['x'], 'p.png') }} onConfirm={vi.fn()} onCancel={vi.fn()} />);
    const img = await waitFor(() => { const i = container.querySelector('img.banner-cropper-img'); if (!i) throw new Error('n'); return i; });
    expect(img.closest('.banner-cropper-frame')).toBeTruthy();
    const stage = container.querySelector('.banner-cropper-stage');
    expect(stage.contains(container.querySelector('.banner-cropper-bar'))).toBe(false);
    expect(stage.contains(container.querySelector('.banner-cropper-controls'))).toBe(false);
  });
});
