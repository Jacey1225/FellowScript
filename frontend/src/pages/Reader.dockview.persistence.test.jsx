// Regression coverage for the specific risk the black/gold restyle spec
// (20260816-web-reader-black-gold-restyle-implementation) calls out by name:
// this is a value/token-only restyle pass that must leave the dockview
// drag/split/tab-reorder/layout-persistence mechanism
// (frontend/src/lib/readerDockLayout.js) completely intact. The prior
// redesign pass on this same page (20260816-web-reader-redesign-implementation)
// was bounced by the testing gate for a real structural bug hiding behind a
// purely visual/color-focused check, so per this task's acceptance criteria
// the mechanism itself — not just its appearance — must be exercised here.
//
// This wires DockviewReact exactly the way Reader.jsx's handleDockviewReady
// does (loadSavedLayout, falling back to buildDefaultLayout; onDidLayoutChange
// debounced into saveLayout) and drives real dockview panel-api `moveTo()`
// calls — the same underlying operation dockview's own pointer-drag
// interaction invokes — rather than asserting only against static JSON, so a
// regression that broke the live api.onDidLayoutChange -> saveLayout wiring,
// or fromJSON/toJSON round-tripping itself, would fail here.
//
// Run with: cd frontend && npm test -- --run src/pages/Reader.dockview.persistence.test.jsx
import React from 'react';
import { describe, test, expect, beforeAll, beforeEach, vi } from 'vitest';
import { render, act, cleanup } from '@testing-library/react';
import { DockviewReact } from 'dockview-react';
import {
  PANEL_IDS, buildDefaultLayout, loadSavedLayout, saveLayout, resetLayout, LAYOUT_STORAGE_KEY,
} from '../lib/readerDockLayout.js';

beforeAll(() => {
  if (!window.ResizeObserver) {
    window.ResizeObserver = class {
      observe() {}
      unobserve() {}
      disconnect() {}
    };
  }
});

beforeEach(() => {
  localStorage.clear();
  cleanup();
});

function makePanelComponent(id) {
  return function Panel() {
    return <div data-panel-content={id}>{id}</div>;
  };
}

const PANEL_COMPONENTS = Object.fromEntries(
  Object.values(PANEL_IDS).map((id) => [id, makePanelComponent(id)])
);

// Mirrors Reader.jsx's handleDockviewReady exactly: try to restore a saved
// layout, fall back to the default, then wire the same debounced
// onDidLayoutChange -> saveLayout persistence path.
function mountReaderDock({ debounceMs = 400 } = {}) {
  let apiRef;
  let disposable;
  const onReady = (event) => {
    const api = event.api;
    apiRef = api;
    const loaded = loadSavedLayout(api);
    if (!loaded) buildDefaultLayout(api);
    disposable?.dispose();
    let timer;
    disposable = api.onDidLayoutChange(() => {
      if (timer) clearTimeout(timer);
      timer = setTimeout(() => saveLayout(api), debounceMs);
    });
  };
  const result = render(
    <div className="reader-dock-container dockview-theme-abyss">
      <DockviewReact components={PANEL_COMPONENTS} onReady={onReady} disableFloatingGroups />
    </div>
  );
  return { ...result, getApi: () => apiRef };
}

describe('Reader dockview — tab-reorder drag persists across a reload', () => {
  test('reordering a tab within its group (the drag-to-reorder gesture) round-trips through localStorage', async () => {
    let mounted;
    await act(async () => {
      mounted = mountReaderDock();
    });
    const api = mounted.getApi();

    const notesGroup = api.getPanel(PANEL_IDS.NOTES).group;
    // Default add order (buildDefaultLayout): Notes, then Highlights, then
    // Messaging, all "within" Notes's group.
    expect(notesGroup.panels.map((p) => p.id)).toEqual([
      PANEL_IDS.NOTES, PANEL_IDS.HIGHLIGHTS, PANEL_IDS.MESSAGING,
    ]);

    // The actual gesture dockview's pointer-drag tab-reorder invokes under
    // the hood: move the Messaging tab to index 0 within its own group.
    await act(async () => {
      api.getPanel(PANEL_IDS.MESSAGING).api.moveTo({ index: 0 });
    });
    expect(notesGroup.panels.map((p) => p.id)).toEqual([
      PANEL_IDS.MESSAGING, PANEL_IDS.NOTES, PANEL_IDS.HIGHLIGHTS,
    ]);

    // onDidLayoutChange -> saveLayout is debounced 400ms in the real
    // component; wait past that instead of calling saveLayout directly, so
    // this actually exercises the live wiring, not just the persistence
    // helper in isolation.
    await new Promise((resolve) => setTimeout(resolve, 450));

    const raw = localStorage.getItem(LAYOUT_STORAGE_KEY);
    expect(raw, 'expected onDidLayoutChange to have triggered a debounced saveLayout()').toBeTruthy();
    const parsed = JSON.parse(raw);
    expect(parsed.version).toBe(1);

    // Simulate a full page reload: unmount, remount fresh, and let
    // loadSavedLayout restore from the same localStorage key Reader.jsx uses.
    cleanup();
    let remounted;
    await act(async () => {
      remounted = mountReaderDock();
    });
    const api2 = remounted.getApi();
    const restoredGroup = api2.getPanel(PANEL_IDS.NOTES).group;
    expect(restoredGroup.panels.map((p) => p.id)).toEqual([
      PANEL_IDS.MESSAGING, PANEL_IDS.NOTES, PANEL_IDS.HIGHLIGHTS,
    ]);
  });
});

describe('Reader dockview — split interaction persists across a reload', () => {
  test('splitting a panel into a new group (the drag-to-split gesture) round-trips through localStorage', async () => {
    let mounted;
    await act(async () => {
      mounted = mountReaderDock();
    });
    const api = mounted.getApi();

    const groupCountBefore = api.groups.length;
    expect(groupCountBefore).toBe(3); // Bible, Agent Chat, Notes-tab-group

    const bibleGroup = api.getPanel(PANEL_IDS.BIBLE).group;
    // The actual gesture dockview's pointer-drag split invokes under the
    // hood: drop the Highlights tab onto the right edge of the Bible group,
    // pulling it out of the Notes tab group into its own new group.
    await act(async () => {
      api.getPanel(PANEL_IDS.HIGHLIGHTS).api.moveTo({ group: bibleGroup, position: 'right' });
    });

    const groupCountAfter = api.groups.length;
    expect(groupCountAfter, 'splitting a panel into a new position should create an additional group').toBe(groupCountBefore + 1);
    // Highlights is no longer tabbed with Notes.
    expect(api.getPanel(PANEL_IDS.NOTES).group.panels.map((p) => p.id)).not.toContain(PANEL_IDS.HIGHLIGHTS);

    await new Promise((resolve) => setTimeout(resolve, 450));
    const raw = localStorage.getItem(LAYOUT_STORAGE_KEY);
    expect(raw).toBeTruthy();

    cleanup();
    let remounted;
    await act(async () => {
      remounted = mountReaderDock();
    });
    const api2 = remounted.getApi();
    expect(api2.groups.length).toBe(groupCountAfter);
    expect(api2.getPanel(PANEL_IDS.NOTES).group.panels.map((p) => p.id)).not.toContain(PANEL_IDS.HIGHLIGHTS);
    expect(api2.getPanel(PANEL_IDS.HIGHLIGHTS).group.id).not.toBe(api2.getPanel(PANEL_IDS.NOTES).group.id);
  });
});

describe('Reader dockview — Reset Layout restores and re-persists the default arrangement', () => {
  test('resetLayout discards a reordered/split layout and writes the default back to localStorage', async () => {
    let mounted;
    await act(async () => {
      mounted = mountReaderDock();
    });
    const api = mounted.getApi();

    await act(async () => {
      api.getPanel(PANEL_IDS.HIGHLIGHTS).api.moveTo({ index: 0 });
    });
    expect(api.getPanel(PANEL_IDS.NOTES).group.panels.map((p) => p.id)[0]).toBe(PANEL_IDS.HIGHLIGHTS);

    await act(async () => {
      resetLayout(api);
    });

    expect(api.getPanel(PANEL_IDS.NOTES).group.panels.map((p) => p.id)).toEqual([
      PANEL_IDS.NOTES, PANEL_IDS.HIGHLIGHTS, PANEL_IDS.MESSAGING,
    ]);
    // resetLayout calls saveLayout synchronously (not debounced) — the
    // reset itself is immediately durable, unlike the drag-driven path.
    const raw = localStorage.getItem(LAYOUT_STORAGE_KEY);
    expect(raw).toBeTruthy();
    const parsed = JSON.parse(raw);
    expect(parsed.version).toBe(1);
  });
});
