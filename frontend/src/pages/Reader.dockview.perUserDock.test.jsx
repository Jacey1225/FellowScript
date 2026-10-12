// Per-user layout persistence, untrusted-layout fallback, and reopen-to-last-dock
// (20261011-reader-tab-drag-docks).
import React from 'react';
import { describe, test, expect, beforeAll, beforeEach } from 'vitest';
import { render, act, cleanup } from '@testing-library/react';
import { DockviewReact } from 'dockview-react';
import {
  PANEL_IDS, buildDefaultLayout, loadSavedLayout, saveLayout, resetLayout, reopenPanel,
  layoutStorageKey, isValidSavedLayout, loadLastDock, LAYOUT_STORAGE_KEY,
  LEGACY_LAYOUT_STORAGE_KEY, LAYOUT_VERSION,
} from '../lib/readerDockLayout.js';

beforeAll(() => {
  if (!window.ResizeObserver) {
    window.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
  }
});
beforeEach(() => { localStorage.clear(); cleanup(); });

const COMPONENTS = Object.fromEntries(
  Object.values(PANEL_IDS).map((id) => [id, () => <div>{id}</div>]),
);

async function mount(userId) {
  let api;
  await act(async () => {
    render(
      <DockviewReact components={COMPONENTS} disableFloatingGroups
        onReady={(e) => { api = e.api; if (!loadSavedLayout(api, userId)) buildDefaultLayout(api); }} />,
    );
  });
  return api;
}
const tabs = (api, id) => api.getPanel(id).group.panels.map((p) => p.id);

describe('storage key', () => {
  test('per-user keys, guest fallback, unsafe ids map to guest', () => {
    expect(layoutStorageKey('u1')).toBe('fs_reader_layout_v2:u1');
    expect(layoutStorageKey(null)).toBe('fs_reader_layout_v2:guest');
    expect(layoutStorageKey(undefined)).toBe(LAYOUT_STORAGE_KEY);
    expect(layoutStorageKey('a:b/../x')).toBe(LAYOUT_STORAGE_KEY);
    expect(layoutStorageKey('x'.repeat(200))).toBe(LAYOUT_STORAGE_KEY);
    expect(layoutStorageKey('u1')).not.toBe(layoutStorageKey('u2'));
  });
});

describe('per-user isolation', () => {
  test('user A layout is restored for A, not applied to B', async () => {
    const api = await mount('userA');
    await act(async () => { api.getPanel(PANEL_IDS.HIGHLIGHTS).api.moveTo({ index: 0 }); });
    saveLayout(api, 'userA');
    expect(localStorage.getItem(layoutStorageKey('userA'))).toBeTruthy();
    expect(localStorage.getItem(layoutStorageKey('userB'))).toBeNull();
    cleanup();

    const b = await mount('userB');
    expect(tabs(b, PANEL_IDS.NOTES)[0]).toBe(PANEL_IDS.NOTES);
    cleanup();
    const a = await mount('userA');
    expect(tabs(a, PANEL_IDS.NOTES)[0]).toBe(PANEL_IDS.HIGHLIGHTS);
  });

  test('legacy global v1 key is never applied', async () => {
    const api = await mount('userA');
    const layout = api.toJSON();
    cleanup();
    localStorage.setItem(LEGACY_LAYOUT_STORAGE_KEY, JSON.stringify({ version: 1, layout }));
    const fresh = await mount('userA');
    expect(loadSavedLayout(fresh, 'userA')).toBe(false);
  });
});

describe('untrusted saved layout falls back to default', () => {
  const key = layoutStorageKey('u');
  const cases = {
    'malformed JSON': '{not json',
    'wrong version': JSON.stringify({ version: 1, layout: {} }),
    'null': 'null',
    'unknown panel id': JSON.stringify({ version: LAYOUT_VERSION, layout: {
      grid: {}, panels: { evil: { id: 'evil', contentComponent: 'evil' } } } }),
    'mismatched component': JSON.stringify({ version: LAYOUT_VERSION, layout: {
      grid: {}, panels: { notes: { id: 'notes', contentComponent: 'bible-reader' } } } }),
    'empty panels': JSON.stringify({ version: LAYOUT_VERSION, layout: { grid: {}, panels: {} } }),
    'array layout': JSON.stringify({ version: LAYOUT_VERSION, layout: [] }),
  };
  for (const [name, raw] of Object.entries(cases)) {
    test(name, async () => {
      localStorage.setItem(key, raw);
      const api = await mount('u');
      expect(api.panels.map((p) => p.id).sort()).toEqual(Object.values(PANEL_IDS).sort());
      expect(tabs(api, PANEL_IDS.NOTES)).toEqual([PANEL_IDS.NOTES, PANEL_IDS.HIGHLIGHTS, PANEL_IDS.MESSAGING]);
    });
  }

  test('valid-shaped but structurally broken grid: fromJSON throws, api left empty then default builds', async () => {
    localStorage.setItem(key, JSON.stringify({ version: LAYOUT_VERSION, layout: {
      grid: { root: 'bad' }, panels: { notes: { id: 'notes', contentComponent: 'notes' } } } }));
    const api = await mount('u');
    expect(api.panels.length).toBe(5);
  });

  test('isValidSavedLayout accepts a subset of known panels (closed panels)', async () => {
    const api = await mount('u');
    api.getPanel(PANEL_IDS.MESSAGING).api.close();
    expect(isValidSavedLayout(api.toJSON())).toBe(true);
  });
});

describe('reopen to last dock', () => {
  test('closed panel returns to former tab mate group', async () => {
    const api = await mount('u');
    saveLayout(api, 'u');
    api.getPanel(PANEL_IDS.MESSAGING).api.close();
    saveLayout(api, 'u');
    expect(loadLastDock('u')[PANEL_IDS.MESSAGING].tabmates).toContain(PANEL_IDS.NOTES);
    await act(async () => { reopenPanel(api, PANEL_IDS.MESSAGING, 'u'); });
    expect(tabs(api, PANEL_IDS.MESSAGING)).toContain(PANEL_IDS.NOTES);
  });

  test('moved panel reopens with its last tab mates, not default position', async () => {
    const api = await mount('u');
    // Agent Chat moved into the Notes tab group, then saved and closed.
    await act(async () => {
      api.getPanel(PANEL_IDS.AGENT_CHAT).api.moveTo({ group: api.getPanel(PANEL_IDS.NOTES).group });
    });
    expect(tabs(api, PANEL_IDS.AGENT_CHAT)).toContain(PANEL_IDS.NOTES);
    saveLayout(api, 'u');
    api.getPanel(PANEL_IDS.AGENT_CHAT).api.close();
    saveLayout(api, 'u');
    await act(async () => { reopenPanel(api, PANEL_IDS.AGENT_CHAT, 'u'); });
    // Default would place it below Bible, alone.
    expect(tabs(api, PANEL_IDS.AGENT_CHAT)).toContain(PANEL_IDS.NOTES);
  });

  test('last dock is per user: other user gets default position', async () => {
    const api = await mount('u');
    await act(async () => {
      api.getPanel(PANEL_IDS.AGENT_CHAT).api.moveTo({ group: api.getPanel(PANEL_IDS.NOTES).group });
    });
    saveLayout(api, 'u');
    api.getPanel(PANEL_IDS.AGENT_CHAT).api.close();
    await act(async () => { reopenPanel(api, PANEL_IDS.AGENT_CHAT, 'other'); });
    expect(tabs(api, PANEL_IDS.AGENT_CHAT)).toEqual([PANEL_IDS.AGENT_CHAT]);
  });

  test('no saved info falls back to default rules; open panel is a no-op', async () => {
    const api = await mount('u');
    api.getPanel(PANEL_IDS.AGENT_CHAT).api.close();
    await act(async () => { reopenPanel(api, PANEL_IDS.AGENT_CHAT, 'u'); });
    expect(tabs(api, PANEL_IDS.AGENT_CHAT)).toEqual([PANEL_IDS.AGENT_CHAT]);
    const n = api.panels.length;
    reopenPanel(api, PANEL_IDS.AGENT_CHAT, 'u');
    expect(api.panels.length).toBe(n);
  });

  test('sanitizes tampered lastDock entries', () => {
    localStorage.setItem(layoutStorageKey('u'), JSON.stringify({
      version: LAYOUT_VERSION, layout: {}, lastDock: {
        notes: { side: 'diagonal', tabmates: ['evil', 'notes', 'bible-reader'] }, evil: { side: 'left' },
      } }));
    expect(loadLastDock('u')).toEqual({ notes: { side: null, tabmates: ['bible-reader'] } });
  });
});

describe('reset', () => {
  test('resetLayout restores default and writes per-user record with empty lastDock', async () => {
    const api = await mount('u');
    await act(async () => { api.getPanel(PANEL_IDS.HIGHLIGHTS).api.moveTo({ index: 0 }); });
    await act(async () => { resetLayout(api, 'u'); });
    expect(tabs(api, PANEL_IDS.NOTES)).toEqual([PANEL_IDS.NOTES, PANEL_IDS.HIGHLIGHTS, PANEL_IDS.MESSAGING]);
    const rec = JSON.parse(localStorage.getItem(layoutStorageKey('u')));
    expect(rec.version).toBe(LAYOUT_VERSION);
    expect(rec.lastDock).toEqual({});
  });
});
