// Regression test for the Reader dock structural redesign (design-notes.md
// §3): dockview's grid is a recursive tree of nested SplitViews
// (BranchNode/LeafNode in dockview-core). An earlier, buggy version of the
// inter-group gap rule in reader-dock.css used an unqualified
// `.dv-split-view-container .dv-view-container .dv-view` descendant
// selector, which matched EVERY .dv-view wrapper at every nesting depth --
// not just leaf wrappers that directly contain a .dv-groupview -- so groups
// nested one branch level deeper (Bible + Agent Chat, both children of the
// inner vertical split nested inside the outer horizontal split's left
// branch) picked up an extra compounding layer of `calc(var(--panel-gap)/2)`
// padding vs. the shallower group (the Notes/Highlights/Messages tab group,
// directly under the outer split's right branch), producing a ~4.8px
// misaligned outer edge between panel groups. The fix scopes the rule to
// leaf wrappers only via `.dv-view:has(> .dv-groupview)` (BranchNode's
// wrapper never carries the dv-groupview class, so it's naturally excluded
// regardless of depth).
//
// This proves that selector matches exactly ONE ancestor .dv-view per
// *group* (`.dv-groupview`), for every group in the app's real default
// layout (buildDefaultLayout from readerDockLayout.js, the same layout
// Reader.jsx's onReady wires up) -- including groups nested at different
// depths in the split tree, which is the specific case the bug broke. Note
// this is asserted per-group rather than per-panel: dockview's "always"
// renderer keeps inactive tab panels (Highlights/Messages, tabbed alongside
// Notes) mounted off-tree in a hidden `.dv-render-overlay` for state
// preservation, so only the active tab's content -- and thus the group's
// own .dv-groupview element -- sits inside the real split-view tree the
// gap/radius rules target.
//
// Run with: cd frontend && npm test -- --run src/pages/Reader.dockview.test.jsx
import React from 'react';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { describe, test, expect, beforeAll } from 'vitest';
import { render, act } from '@testing-library/react';
import { DockviewReact } from 'dockview-react';
import { buildDefaultLayout, PANEL_IDS } from '../lib/readerDockLayout.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// dockview-core uses ResizeObserver internally to react to container size
// changes; jsdom doesn't implement it.
beforeAll(() => {
  if (!window.ResizeObserver) {
    window.ResizeObserver = class {
      observe() {}
      unobserve() {}
      disconnect() {}
    };
  }
});

function makePanelComponent(id) {
  return function Panel() {
    return <div data-panel-content={id}>{id}</div>;
  };
}

const PANEL_COMPONENTS = Object.fromEntries(
  Object.values(PANEL_IDS).map((id) => [id, makePanelComponent(id)])
);

// Walks up from `node` counting ancestor elements that match `selector` --
// i.e. how many times the padding rule would apply to this group.
function countMatchingAncestors(node, selector) {
  let count = 0;
  let el = node.parentElement;
  while (el) {
    if (el.matches(selector)) count += 1;
    el = el.parentElement;
  }
  return count;
}

describe('reader-dock.css — gap selector source guard', () => {
  test('the inter-group gap padding rule is scoped to leaf .dv-view wrappers, not every .dv-view at every split-tree depth', () => {
    const rawCss = fs.readFileSync(path.join(__dirname, '../styles/reader-dock.css'), 'utf8');
    // Strip /* ... */ comments first -- otherwise the doc comment above the
    // rule (which discusses both the fixed and the old buggy selector by
    // name) can make a naive "selector text before the rule" match include
    // comment prose instead of the actual CSS selector.
    const css = rawCss.replace(/\/\*[\s\S]*?\*\//g, '');
    const match = css.match(/([^{}]+)\{\s*padding:\s*calc\(var\(--panel-gap\)\s*\/\s*2\)/);
    expect(match, 'expected to find the inter-group gap padding rule (padding: calc(var(--panel-gap) / 2)) in reader-dock.css').toBeTruthy();
    const selector = match[1].trim();
    // The fixed, leaf-scoped selector.
    expect(selector).toContain(':has(> .dv-groupview)');
    // The old buggy selector matched every .dv-view descendant regardless of
    // nesting depth -- guard against silently reintroducing it verbatim.
    expect(selector).not.toBe('.dockview-theme-abyss .dv-split-view-container .dv-view-container .dv-view');
  });
});

describe('Reader dockview group gap — leaf-only selector invariant', () => {
  test('every group (.dv-groupview) has exactly one ancestor .dv-view:has(> .dv-groupview), regardless of split-tree depth', async () => {
    let container;
    await act(async () => {
      ({ container } = render(
        <div className="reader-dock-container dockview-theme-abyss">
          <DockviewReact
            components={PANEL_COMPONENTS}
            onReady={(event) => buildDefaultLayout(event.api)}
            disableFloatingGroups
          />
        </div>
      ));
    });

    const groups = Array.from(container.querySelectorAll('.dv-groupview'));
    // Sanity check: the default layout really does produce multiple groups
    // nested at different split-tree depths (Bible/Agent Chat under the
    // outer split's left branch's inner vertical split; the Notes tab group
    // directly under the outer split's right branch) -- otherwise this test
    // could pass vacuously without ever exercising the bug this guards
    // against.
    expect(groups.length).toBe(3);
    const labels = groups.map((g) => g.getAttribute('aria-label')).sort();
    expect(labels).toEqual(['Agent Chat', 'Bible', 'Notes']);

    const counts = groups.map((g) => ({
      label: g.getAttribute('aria-label'),
      count: countMatchingAncestors(g, '.dv-view:has(> .dv-groupview)'),
    }));

    // Every group gets exactly one layer of gap padding...
    for (const { label, count } of counts) {
      expect(count, `group "${label}" matched ${count} ancestor .dv-view wrappers, expected exactly 1`).toBe(1);
    }
    // ...and therefore all groups are uniform, including the Bible/Agent
    // Chat groups nested one level deeper than the Notes group (the
    // specific case the bug broke).
    const uniqueCounts = new Set(counts.map((c) => c.count));
    expect(uniqueCounts.size).toBe(1);
  });

  test('inactive same-group tabs (Highlights/Messages) render off-tree via renderer="always" and are unaffected by the gap rule', async () => {
    let container;
    await act(async () => {
      ({ container } = render(
        <div className="reader-dock-container dockview-theme-abyss">
          <DockviewReact
            components={PANEL_COMPONENTS}
            onReady={(event) => buildDefaultLayout(event.api)}
            disableFloatingGroups
          />
        </div>
      ));
    });

    // Highlights and Messages are tabbed with Notes and inactive by default
    // (see readerDockLayout.js), so their content mounts in dockview's
    // hidden `.dv-render-overlay`, not inside the visible split-view tree.
    for (const id of [PANEL_IDS.HIGHLIGHTS, PANEL_IDS.MESSAGING]) {
      const content = container.querySelector(`[data-panel-content="${id}"]`);
      expect(content, `panel "${id}" did not render`).toBeTruthy();
      expect(content.closest('.dv-render-overlay'), `panel "${id}" expected to be off-tree while inactive`).toBeTruthy();
      expect(content.closest('.dv-groupview'), `panel "${id}" should not sit inside a .dv-groupview while inactive`).toBeFalsy();
    }

    // The active tab in that same group (Notes) IS inside the tree, inside
    // exactly one gap-padded .dv-view wrapper.
    const notesContent = container.querySelector(`[data-panel-content="${PANEL_IDS.NOTES}"]`);
    expect(notesContent).toBeTruthy();
    expect(countMatchingAncestors(notesContent, '.dv-view:has(> .dv-groupview)')).toBe(1);
  });
});
