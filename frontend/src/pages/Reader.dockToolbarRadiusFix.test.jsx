// Regression test for the toolbar-radius fix
// (.claude/pipeline/20260825-dockable-toolbar-radius-fix): a fourth corrective
// pass on top of 20260825-dockable-glass-fix, 20260825-dockable-glass-audit,
// and 20260825-dockable-outline-fix, in the same live-verification thread.
//
// Defect 1 (toolbar strip): .bible-panel-toolbar declared its own
// `background: var(--panel-glass-bg)` + `backdrop-filter: blur(...)
// saturate(160%)` on top of .dv-groupview's already-blurred/saturated
// surface beneath it -- two independently-composited blur+saturate layers
// stack to a measurably different flat tone than the single-blur surface
// below, even though the declared background token matched, plus an ad-hoc
// cool white-tinted border-bottom never using --border-glass. Fix: the row
// now paints nothing of its own (background: transparent; backdrop-filter:
// none) and drops the border-bottom, so .dv-groupview's single glass
// surface shows straight through.
//
// Defect 2 (squared outline behind the tab strip): despite .dv-groupview's
// own border-radius/overflow:hidden clipping correctly (confirmed live,
// 20260825-dockable-outline-fix), dockview-core's own shipped
// `.dv-split-view-container.dv-separator-border .dv-view:not(:first-child)
// ::before` structural separator hairline lives on a sibling wrapper OUTSIDE
// .dv-groupview, so it was never subject to that clipping -- and still used
// an ad-hoc cool white-tinted --dv-separator-border token. Per the user's
// explicit ask this pass (round it, since delete/transparent was already
// tried on .dv-groupview's border in the prior task), --dv-separator-border
// now reuses --border-glass and the separator's ::before gets a
// border-radius plus a thickness/inset large enough for that radius to read.
//
// This is a source-guard test (same pattern as Reader.dockGlassFix.test.jsx /
// Reader.dockGlassAudit.test.jsx / Reader.dockOutlineFix.test.jsx), since
// jsdom doesn't implement backdrop-filter/border-radius-on-pseudo-element
// compositing well enough to assert the actual composited look. Live-render
// verification (computed styles + pixel sampling + screenshots against the
// running dev server) was done separately by the frontend gate and is
// recorded in frontend.json / this task's testing.json, not here.
//
// Run with: cd frontend && npm test -- --run src/pages/Reader.dockToolbarRadiusFix.test.jsx
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { describe, test, expect } from 'vitest';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function readStripped(relPath) {
  const raw = fs.readFileSync(path.join(__dirname, relPath), 'utf8');
  return raw.replace(/\/\*[\s\S]*?\*\//g, '');
}

describe('reader-dock.css — .bible-panel-toolbar no longer paints its own surface (toolbar-strip defect)', () => {
  test('.bible-panel-toolbar background is transparent, not var(--panel-glass-bg)', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.bible-panel-toolbar\s*\{([^}]*)\}/);
    expect(match, 'expected a .bible-panel-toolbar rule').toBeTruthy();
    expect(match[1]).toMatch(/background:\s*transparent;/);
    expect(match[1]).not.toMatch(/var\(--panel-glass-bg\)/);
  });

  test('.bible-panel-toolbar no longer composites its own backdrop-filter', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.bible-panel-toolbar\s*\{([^}]*)\}/);
    expect(match[1]).toMatch(/backdrop-filter:\s*none;/);
    expect(match[1]).not.toMatch(/blur\(/);
  });

  test('.bible-panel-toolbar no longer draws its own ad-hoc border-bottom seam', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.bible-panel-toolbar\s*\{([^}]*)\}/);
    expect(match[1]).not.toMatch(/border-bottom/);
  });
});

describe('reader-dock.css — dockview-core split-view separator retinted + rounded (squared-outline defect)', () => {
  test('--dv-separator-border reuses --border-glass instead of the ad-hoc cool white value', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.dockview-theme-abyss\s*\{([^]*?)\n\}/);
    expect(match, 'expected the .dockview-theme-abyss token block').toBeTruthy();
    expect(match[1]).toMatch(/--dv-separator-border:\s*var\(--border-glass\);/);
    expect(match[1]).not.toMatch(/--dv-separator-border:\s*rgba\(255,\s*255,\s*255/);
  });

  test('the separator pseudo-element gets a border-radius so rounding is legible', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.dockview-theme-abyss \.dv-split-view-container\.dv-separator-border \.dv-view:not\(:first-child\)::before\s*\{([^}]*)\}/);
    expect(match, 'expected a rounded-separator rule targeting the dockview-core separator ::before').toBeTruthy();
    expect(match[1]).toMatch(/border-radius:\s*\S/);
  });

  test('horizontal separator is thickened and inset so the radius is visible and stays within the panel footprint', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.dockview-theme-abyss \.dv-split-view-container\.dv-horizontal[^{]*::before\s*\{([^}]*)\}/);
    expect(match, 'expected a horizontal separator sizing rule').toBeTruthy();
    expect(match[1]).toMatch(/width:\s*3px/);
    expect(match[1]).toMatch(/top:\s*calc\(var\(--panel-gap\)/);
    expect(match[1]).toMatch(/bottom:\s*calc\(var\(--panel-gap\)/);
  });

  test('vertical separator is thickened and inset so the radius is visible and stays within the panel footprint', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.dockview-theme-abyss \.dv-split-view-container\.dv-vertical[^{]*::before\s*\{([^}]*)\}/);
    expect(match, 'expected a vertical separator sizing rule').toBeTruthy();
    expect(match[1]).toMatch(/height:\s*3px/);
    expect(match[1]).toMatch(/left:\s*calc\(var\(--panel-gap\)/);
    expect(match[1]).toMatch(/right:\s*calc\(var\(--panel-gap\)/);
  });
});

describe('reader-dock.css — no regression to the three prior fixes in this thread', () => {
  test('.dv-groupview still clips + rounds its own corners (outline-fix, defect 2 root treatment)', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.dockview-theme-abyss \.dv-groupview\s*\{([^}]*)\}/);
    expect(match, 'expected a .dockview-theme-abyss .dv-groupview rule').toBeTruthy();
    expect(match[1]).toMatch(/border-radius:\s*var\(--radius-lg\);/);
    expect(match[1]).toMatch(/overflow:\s*hidden;/);
  });

  test('.dv-groupview still uses the warm border-glass/shadow-glass tokens (outline-fix)', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.dockview-theme-abyss \.dv-groupview\s*\{([^}]*)\}/);
    expect(match[1]).toMatch(/border:\s*1px solid var\(--border-glass\);/);
    expect(match[1]).toMatch(/box-shadow:\s*var\(--shadow-glass\);/);
  });

  test('.dv-groupview glass fill + blur (glass-fix / glass-audit) is unaffected', () => {
    const css = readStripped('../styles/reader-dock.css');
    expect(css).toMatch(/\.dockview-theme-abyss \.dv-groupview\s*\{[^}]*background:\s*var\(--panel-glass-bg\)/);
    expect(css).toMatch(/\.dockview-theme-abyss \.dv-groupview\s*\{[^}]*backdrop-filter:\s*blur\(var\(--panel-glass-blur\)\)/);
  });

  test('tab-strip fill is still transparent (glass-audit fix)', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.dockview-theme-abyss \.dv-tabs-and-actions-container\s*\{([^}]*)\}/);
    expect(match, 'expected a .dv-tabs-and-actions-container rule').toBeTruthy();
    expect(match[1]).toMatch(/background:\s*transparent/);
  });

  test('Bible-panel body fill is still transparent (glass-audit fix)', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.bible-panel-body\s*\{([^}]*)\}/);
    expect(match, 'expected a .bible-panel-body rule').toBeTruthy();
    expect(match[1]).toMatch(/background:\s*transparent/);
  });

  // The drag-handle grip glyph (glass-audit fix) this used to guard the
  // presence of was deliberately removed by 20260825-reader-dock-rail-polish's
  // item 1 — see Reader.dockGlassAudit.test.jsx's own updated describe block
  // for the "now guards absence" coverage of that removal.

  test('.dv-dockview root transparency (glass-fix defect) is still present', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.dockview-theme-abyss \.dv-dockview\s*\{([^}]*)\}/);
    expect(match, 'expected a .dockview-theme-abyss .dv-dockview rule').toBeTruthy();
    expect(match[1]).toMatch(/background-color:\s*transparent/);
  });
});
