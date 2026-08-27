// Regression coverage for the left dock rail (20260825-reader-dock-rail-polish,
// item 3): a new fixed left-edge icon rail that mirrors the live dockview
// panel-open/active state and lets a user click an icon to reveal a
// backgrounded tab or re-add a closed panel to the layout.
//
// Three layers of coverage, matching how the feature is actually built:
//   1. `reopenPanel` (readerDockLayout.js) in isolation against a real
//      DockviewApi — the positioning logic for each of the 5 panel types,
//      including panels with no sensible anchor to attach to.
//   2. `ReaderDockRail` in isolation — the active(filled-gold)/inactive-or-
//      closed(60%-opacity-outline) visual-state contract for all 5 panel
//      icons across several open/closed/active combinations, per the
//      ground-truth spec (dockable-glass-layout §3.4).
//   3. An integration harness that wires DockviewReact + ReaderDockRail
//      together exactly the way Reader.jsx does (onDidAddPanel/
//      onDidRemovePanel/onDidActivePanelChange -> openPanelIds/activePanelId
//      state; handleRailSelect -> activate-if-open else reopenPanel) and
//      drives real panel.api.close() calls (the same operation a tab's ×
//      button invokes) plus real rail clicks, for every panel — not just
//      Notes.
//
// Run with: cd frontend && npm test -- --run src/pages/Reader.dockRail.test.jsx
import React, { useCallback, useRef, useState } from 'react';
import { describe, test, expect, beforeAll, beforeEach, vi } from 'vitest';
import { render, act, cleanup, fireEvent } from '@testing-library/react';
import { DockviewReact } from 'dockview-react';
import { PANEL_IDS, PANEL_TITLES, buildDefaultLayout, reopenPanel } from '../lib/readerDockLayout.js';
import ReaderDockRail from '../components/panels/ReaderDockRail.jsx';

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

const ALL_IDS = Object.values(PANEL_IDS);

// ── Layer 1: reopenPanel positioning ─────────────────────────────────────────

describe('readerDockLayout.reopenPanel', () => {
  async function mountDefault() {
    let apiRef;
    await act(async () => {
      render(
        <div className="reader-dock-container dockview-theme-abyss">
          <DockviewReact components={PANEL_COMPONENTS} onReady={(e) => { apiRef = e.api; buildDefaultLayout(e.api); }} disableFloatingGroups />
        </div>
      );
    });
    return apiRef;
  }

  test('is a no-op when the panel is already open', async () => {
    const api = await mountDefault();
    const before = api.panels.map((p) => p.id).sort();
    await act(async () => { reopenPanel(api, PANEL_IDS.NOTES); });
    expect(api.panels.map((p) => p.id).sort()).toEqual(before);
  });

  test('reopening Notes/Highlights/Messaging lands tabbed with whichever sibling is still open', async () => {
    const api = await mountDefault();
    await act(async () => { api.getPanel(PANEL_IDS.HIGHLIGHTS).api.close(); });
    expect(api.getPanel(PANEL_IDS.HIGHLIGHTS)).toBeFalsy();

    await act(async () => { reopenPanel(api, PANEL_IDS.HIGHLIGHTS); });
    const reopened = api.getPanel(PANEL_IDS.HIGHLIGHTS);
    expect(reopened).toBeTruthy();
    // Tabbed into the same group as its still-open sibling (Notes), not a
    // stray new top-level group.
    expect(reopened.group.id).toBe(api.getPanel(PANEL_IDS.NOTES).group.id);
    // reopenPanel activates the panel it just re-added.
    expect(api.activePanel?.id).toBe(PANEL_IDS.HIGHLIGHTS);
  });

  test('reopening Agent Chat lands docked below Bible', async () => {
    const api = await mountDefault();
    await act(async () => { api.getPanel(PANEL_IDS.AGENT_CHAT).api.close(); });

    await act(async () => { reopenPanel(api, PANEL_IDS.AGENT_CHAT); });
    const reopened = api.getPanel(PANEL_IDS.AGENT_CHAT);
    expect(reopened).toBeTruthy();
    // "Below Bible" -> a distinct group from Bible's own group, but not
    // tabbed with the Notes/Highlights/Messaging group either.
    expect(reopened.group.id).not.toBe(api.getPanel(PANEL_IDS.BIBLE).group.id);
    expect(reopened.group.id).not.toBe(api.getPanel(PANEL_IDS.NOTES).group.id);
  });

  test('reopening Bible anchors left of whichever Notes-tab-group panel is open', async () => {
    const api = await mountDefault();
    await act(async () => { api.getPanel(PANEL_IDS.BIBLE).api.close(); });
    expect(api.getPanel(PANEL_IDS.BIBLE)).toBeFalsy();

    await act(async () => { reopenPanel(api, PANEL_IDS.BIBLE); });
    const reopened = api.getPanel(PANEL_IDS.BIBLE);
    expect(reopened).toBeTruthy();
    expect(reopened.group.id).not.toBe(api.getPanel(PANEL_IDS.NOTES).group.id);
    expect(api.activePanel?.id).toBe(PANEL_IDS.BIBLE);
  });

  // The orchestrator's explicit ask: a panel reopened with no sensible
  // anchor left in the live layout (every other panel already closed) must
  // still land somewhere sane -- reopenPanel's documented fallback is an
  // unpositioned addPanel (its own new top-level group) rather than an
  // exception or a silently-dropped call.
  test('reopening a panel with no open anchor left in the layout falls back to an unpositioned new group, not a crash or no-op', async () => {
    const api = await mountDefault();
    await act(async () => {
      for (const id of ALL_IDS) api.getPanel(id)?.api.close();
    });
    expect(api.panels.length).toBe(0);

    await act(async () => { reopenPanel(api, PANEL_IDS.NOTES); });
    expect(api.getPanel(PANEL_IDS.NOTES)).toBeTruthy();
    expect(api.panels.length).toBe(1);
    expect(api.activePanel?.id).toBe(PANEL_IDS.NOTES);

    // A second panel type reopened after that still finds Notes as an
    // anchor and doesn't itself need the bare fallback.
    await act(async () => { reopenPanel(api, PANEL_IDS.AGENT_CHAT); });
    expect(api.getPanel(PANEL_IDS.AGENT_CHAT)).toBeTruthy();
    expect(api.panels.length).toBe(2);
  });

  test('reopening every one of the 5 PANEL_IDS types after closing all of them succeeds for each', async () => {
    const api = await mountDefault();
    await act(async () => {
      for (const id of ALL_IDS) api.getPanel(id)?.api.close();
    });
    expect(api.panels.length).toBe(0);

    for (const id of ALL_IDS) {
      await act(async () => { reopenPanel(api, id); });
      expect(api.getPanel(id), `expected ${id} to reopen successfully`).toBeTruthy();
    }
    expect(api.panels.map((p) => p.id).sort()).toEqual([...ALL_IDS].sort());
  });
});

// ── Layer 2: ReaderDockRail visual-state contract ────────────────────────────

describe('ReaderDockRail — active vs inactive/available visual state', () => {
  test('renders exactly one icon per existing panel type, in PANEL_IDS order', () => {
    const { container } = render(
      <ReaderDockRail openPanelIds={new Set(ALL_IDS)} activePanelId={PANEL_IDS.BIBLE} onSelect={() => {}} />
    );
    const buttons = Array.from(container.querySelectorAll('.reader-dock-rail-icon'));
    expect(buttons.map((b) => b.dataset.panelId)).toEqual(ALL_IDS);
  });

  test('every panel type gets the correct active/inactive class across open, closed, and backgrounded-tab combinations', () => {
    // Deliberately covers all 5 panels in a mixed combination, not just the
    // single panel spot-checked live (Notes): Bible active+open, Notes
    // open-but-backgrounded (tabbed behind Highlights), Highlights active,
    // Messaging closed, Agent Chat closed.
    const openPanelIds = new Set([PANEL_IDS.BIBLE, PANEL_IDS.NOTES, PANEL_IDS.HIGHLIGHTS]);
    const activePanelId = PANEL_IDS.HIGHLIGHTS;

    const { container } = render(
      <ReaderDockRail openPanelIds={openPanelIds} activePanelId={activePanelId} onSelect={() => {}} />
    );

    const stateFor = (id) => container.querySelector(`.reader-dock-rail-icon[data-panel-id="${id}"]`);

    // Active/open: filled-gold state (the `active` class) + aria-pressed true.
    const highlights = stateFor(PANEL_IDS.HIGHLIGHTS);
    expect(highlights.className).toContain('active');
    expect(highlights.getAttribute('aria-pressed')).toBe('true');
    expect(highlights.dataset.panelOpen).toBe('true');

    // Open but not active (backgrounded tab, e.g. Notes tabbed behind
    // Highlights): NOT filled-gold (no `active` class), but distinguishable
    // from a genuinely closed panel via data-panel-open.
    const notes = stateFor(PANEL_IDS.NOTES);
    expect(notes.className).not.toContain('active');
    expect(notes.getAttribute('aria-pressed')).toBe('false');
    expect(notes.dataset.panelOpen).toBe('true');

    // Bible is open but NOT the active panel in this scenario (Highlights
    // is) -- open-but-not-active, same as Notes above.
    const bible = stateFor(PANEL_IDS.BIBLE);
    expect(bible.className).not.toContain('active');
    expect(bible.dataset.panelOpen).toBe('true');

    // Closed/available (Messaging, Agent Chat): no `active` class, and
    // data-panel-open reflects closed so CSS/QA can target the 60%-opacity
    // outline state distinctly from an open-but-backgrounded tab.
    for (const id of [PANEL_IDS.MESSAGING, PANEL_IDS.AGENT_CHAT]) {
      const el = stateFor(id);
      expect(el.className, `${id} should not carry the active/filled-gold class while closed`).not.toContain('active');
      expect(el.getAttribute('aria-pressed')).toBe('false');
      expect(el.dataset.panelOpen).toBe('false');
    }
  });

  test('all five panels closed: no icon carries the active class', () => {
    const { container } = render(
      <ReaderDockRail openPanelIds={new Set()} activePanelId={null} onSelect={() => {}} />
    );
    const buttons = Array.from(container.querySelectorAll('.reader-dock-rail-icon'));
    expect(buttons).toHaveLength(ALL_IDS.length);
    for (const b of buttons) {
      expect(b.className).not.toContain('active');
      expect(b.dataset.panelOpen).toBe('false');
    }
  });

  test('all five panels open and active is impossible (only one can be active) but all five open-and-not-active render consistently', () => {
    // No panel is "active" (e.g. focus transiently outside any panel) while
    // all five remain open -- every icon should read open-but-not-filled.
    const { container } = render(
      <ReaderDockRail openPanelIds={new Set(ALL_IDS)} activePanelId={null} onSelect={() => {}} />
    );
    const buttons = Array.from(container.querySelectorAll('.reader-dock-rail-icon'));
    for (const b of buttons) {
      expect(b.className).not.toContain('active');
      expect(b.dataset.panelOpen).toBe('true');
    }
  });

  test('clicking a rail icon invokes onSelect with that panel id, regardless of open/closed state', () => {
    const onSelect = vi.fn();
    const { container } = render(
      <ReaderDockRail openPanelIds={new Set([PANEL_IDS.BIBLE])} activePanelId={PANEL_IDS.BIBLE} onSelect={onSelect} />
    );
    fireEvent.click(container.querySelector(`[data-panel-id="${PANEL_IDS.AGENT_CHAT}"]`));
    expect(onSelect).toHaveBeenCalledWith(PANEL_IDS.AGENT_CHAT);
  });

  test('closed panels get an "Open <title>" tooltip; open panels get just the title', () => {
    const { container } = render(
      <ReaderDockRail openPanelIds={new Set([PANEL_IDS.BIBLE])} activePanelId={PANEL_IDS.BIBLE} onSelect={() => {}} />
    );
    expect(container.querySelector(`[data-panel-id="${PANEL_IDS.BIBLE}"]`).title).toBe(PANEL_TITLES[PANEL_IDS.BIBLE]);
    expect(container.querySelector(`[data-panel-id="${PANEL_IDS.NOTES}"]`).title).toBe(`Open ${PANEL_TITLES[PANEL_IDS.NOTES]}`);
  });
});

// ── Layer 3: integration — DockviewReact + ReaderDockRail wired exactly like Reader.jsx ──

describe('Reader dock rail — end-to-end open/close/reopen wiring', () => {
  test('closing a panel via its tab close button (panel.api.close()) drops it out of the active rail state, and re-selecting it via the rail reopens it as active', async () => {
    let container;
    let apiHandle;
    await act(async () => {
      const rendered = render(<ReaderDockHarnessWithApiExposed onApi={(a) => { apiHandle = a; }} />);
      container = rendered.container;
    });

    const railIcon = (id) => container.querySelector(`.reader-dock-rail-icon[data-panel-id="${id}"]`);

    // Bible is the default active panel.
    expect(railIcon(PANEL_IDS.BIBLE).className).toContain('active');
    expect(railIcon(PANEL_IDS.NOTES).dataset.panelOpen).toBe('true');

    // Simulate the tab's × button: dockview-core's real close() call.
    await act(async () => { apiHandle.getPanel(PANEL_IDS.NOTES).api.close(); });

    expect(railIcon(PANEL_IDS.NOTES).className).not.toContain('active');
    expect(railIcon(PANEL_IDS.NOTES).dataset.panelOpen).toBe('false');
    // Dockview auto-activates a sibling tab (Highlights) when the active tab
    // in a group closes -- mirrors the orchestrator's live spot-check
    // ("Messages tab became selected" after closing Notes).
    expect(container.querySelector('.reader-dock-rail-icon.active')).toBeTruthy();

    // Click the rail's Notes icon: should reopen it and make it active.
    await act(async () => { fireEvent.click(railIcon(PANEL_IDS.NOTES)); });
    expect(apiHandle.getPanel(PANEL_IDS.NOTES)).toBeTruthy();
    expect(railIcon(PANEL_IDS.NOTES).className).toContain('active');
    expect(railIcon(PANEL_IDS.NOTES).dataset.panelOpen).toBe('true');
  });

  test('clicking the rail icon of an open-but-backgrounded tab activates it without reopening (no duplicate panel)', async () => {
    let container;
    let apiHandle;
    await act(async () => {
      const rendered = render(<ReaderDockHarnessWithApiExposed onApi={(a) => { apiHandle = a; }} />);
      container = rendered.container;
    });
    const railIcon = (id) => container.querySelector(`.reader-dock-rail-icon[data-panel-id="${id}"]`);

    // Highlights is open (tabbed behind Notes) but not active by default.
    expect(apiHandle.getPanel(PANEL_IDS.HIGHLIGHTS)).toBeTruthy();
    expect(railIcon(PANEL_IDS.HIGHLIGHTS).className).not.toContain('active');

    const panelCountBefore = apiHandle.panels.length;
    await act(async () => { fireEvent.click(railIcon(PANEL_IDS.HIGHLIGHTS)); });

    expect(apiHandle.panels.length).toBe(panelCountBefore); // no duplicate panel added
    expect(railIcon(PANEL_IDS.HIGHLIGHTS).className).toContain('active');
  });

  test('every one of the 5 panels round-trips through close -> rail-reflects-closed -> rail-click-reopens -> rail-reflects-active', async () => {
    for (const id of ALL_IDS) {
      let container;
      let apiHandle;
      await act(async () => {
        cleanup();
        const rendered = render(<ReaderDockHarnessWithApiExposed onApi={(a) => { apiHandle = a; }} />);
        container = rendered.container;
      });
      const railIcon = () => container.querySelector(`.reader-dock-rail-icon[data-panel-id="${id}"]`);

      await act(async () => { apiHandle.getPanel(id).api.close(); });
      expect(railIcon().dataset.panelOpen, `${id} should read closed on the rail after api.close()`).toBe('false');
      expect(railIcon().className, `${id} should not be active while closed`).not.toContain('active');

      await act(async () => { fireEvent.click(railIcon()); });
      expect(apiHandle.getPanel(id), `${id} should exist again after its rail icon is clicked`).toBeTruthy();
      expect(railIcon().dataset.panelOpen, `${id} should read open on the rail after reopening`).toBe('true');
      expect(railIcon().className, `${id} should become the active rail icon once reopened`).toContain('active');
    }
  });
});

// Same harness as above, but exposes the live DockviewApi to the test via a
// callback prop -- needed because dockview's api instance isn't otherwise
// reachable from outside the component tree once mounted.
function ReaderDockHarnessWithApiExposed({ onApi }) {
  const apiRef = useRef(null);
  const [openPanelIds, setOpenPanelIds] = useState(() => new Set());
  const [activePanelId, setActivePanelId] = useState(null);

  const onReady = useCallback((event) => {
    const api = event.api;
    apiRef.current = api;
    buildDefaultLayout(api);
    const syncOpenPanels = () => setOpenPanelIds(new Set(api.panels.map((p) => p.id)));
    syncOpenPanels();
    setActivePanelId(api.activePanel?.id ?? null);
    api.onDidAddPanel(syncOpenPanels);
    api.onDidRemovePanel(syncOpenPanels);
    api.onDidActivePanelChange((e) => setActivePanelId(e?.panel?.id ?? null));
    onApi?.(api);
  }, [onApi]);

  const handleRailSelect = useCallback((id) => {
    const api = apiRef.current;
    if (!api) return;
    const panel = api.getPanel(id);
    if (panel) panel.api.setActive();
    else reopenPanel(api, id);
  }, []);

  return (
    <>
      <ReaderDockRail openPanelIds={openPanelIds} activePanelId={activePanelId} onSelect={handleRailSelect} />
      <div className="reader-dock-container dockview-theme-abyss">
        <DockviewReact components={PANEL_COMPONENTS} onReady={onReady} disableFloatingGroups />
      </div>
    </>
  );
}
