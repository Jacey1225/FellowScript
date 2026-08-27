// Regression test for the dockable-outline-fix follow-up
// (.claude/pipeline/20260825-dockable-outline-fix): a third corrective pass on
// top of 20260825-dockable-glass-fix and 20260825-dockable-glass-audit. Once
// the tab-strip's opaque fill was removed (glass-audit), .dv-groupview's own
// panel-edge border+shadow started reading as a separately-floating hollow
// rectangle behind the tab strip, because it was painted with the generic,
// cool white-tinted --card-border (rgba(255,255,255,0.08)) and an ad-hoc
// heavier box-shadow instead of the ground-truth spec's own warm-toned
// --border-glass/--shadow-glass tokens (design-spec.md §4.1:
// --border-glass = rgba(237,230,214,0.10), --shadow-glass = 0 8px 24px
// rgba(0,0,0,0.35)).
//
// This is a source-guard test (same pattern as Reader.dockGlassFix.test.jsx /
// Reader.dockGlassAudit.test.jsx), since jsdom doesn't implement
// backdrop-filter/box-shadow compositing well enough to assert the actual
// composited look. Live-render verification (computed styles + pixel
// sampling + screenshots via headless Chromium against the running dev
// server) was done separately by the frontend gate and is recorded in
// frontend.json / this task's testing.json, not here.
//
// Run with: cd frontend && npm test -- --run src/pages/Reader.dockOutlineFix.test.jsx
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { describe, test, expect } from 'vitest';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function readStripped(relPath) {
  const raw = fs.readFileSync(path.join(__dirname, relPath), 'utf8');
  return raw.replace(/\/\*[\s\S]*?\*\//g, '');
}

describe('reader-dock.css — --border-glass / --shadow-glass tokens (design-spec.md §4.1)', () => {
  test('.dockview-theme-abyss defines --border-glass at the spec\'s exact warm-toned value', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.dockview-theme-abyss\s*\{([^]*?)\n\}/);
    expect(match, 'expected the .dockview-theme-abyss token block').toBeTruthy();
    expect(match[1]).toMatch(/--border-glass:\s*rgba\(237,\s*230,\s*214,\s*0\.10\);/);
  });

  test('.dockview-theme-abyss defines --shadow-glass at the spec\'s exact value', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.dockview-theme-abyss\s*\{([^]*?)\n\}/);
    expect(match, 'expected the .dockview-theme-abyss token block').toBeTruthy();
    expect(match[1]).toMatch(/--shadow-glass:\s*0 8px 24px rgba\(0,\s*0,\s*0,\s*0\.35\);/);
  });

  test('--border-glass/--shadow-glass are scoped inside .dockview-theme-abyss, not leaked into global.css', () => {
    const globalCss = readStripped('../styles/global.css');
    expect(globalCss).not.toMatch(/--border-glass:/);
    expect(globalCss).not.toMatch(/--shadow-glass:/);
  });
});

describe('reader-dock.css — .dv-groupview panel-edge border/shadow use the spec tokens, not the generic card ones (outline defect)', () => {
  test('.dv-groupview border uses var(--border-glass), not var(--card-border)', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.dockview-theme-abyss \.dv-groupview\s*\{([^}]*)\}/);
    expect(match, 'expected a .dockview-theme-abyss .dv-groupview rule').toBeTruthy();
    expect(match[1]).toMatch(/border:\s*1px solid var\(--border-glass\);/);
    expect(match[1]).not.toMatch(/var\(--card-border\)/);
  });

  test('.dv-groupview box-shadow uses var(--shadow-glass), not an inlined ad-hoc shadow', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.dockview-theme-abyss \.dv-groupview\s*\{([^}]*)\}/);
    expect(match[1]).toMatch(/box-shadow:\s*var\(--shadow-glass\);/);
    // the old ad-hoc shadow this replaced
    expect(match[1]).not.toMatch(/rgba\(0,\s*0,\s*0,\s*0\.5\)/);
  });

  test('.dv-groupview still carries real border+shadow chrome (not stripped to borderless per spec §3.1/§4.1)', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.dockview-theme-abyss \.dv-groupview\s*\{([^}]*)\}/);
    expect(match[1]).toMatch(/border:\s*1px solid/);
    expect(match[1]).toMatch(/box-shadow:\s*\S/);
  });

  test('.dv-groupview glass fill + blur (from the two prior fixes in this thread) is unaffected by the token swap', () => {
    const css = readStripped('../styles/reader-dock.css');
    expect(css).toMatch(/\.dockview-theme-abyss \.dv-groupview\s*\{[^}]*background:\s*var\(--panel-glass-bg\)/);
    expect(css).toMatch(/\.dockview-theme-abyss \.dv-groupview\s*\{[^}]*backdrop-filter:\s*blur\(var\(--panel-glass-blur\)\)/);
  });
});

describe('reader-dock.css — no regression to the two prior fixes in this thread', () => {
  test('tab-strip fill is still transparent (glass-audit fix, defect 1)', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.dockview-theme-abyss \.dv-tabs-and-actions-container\s*\{([^}]*)\}/);
    expect(match, 'expected a .dv-tabs-and-actions-container rule').toBeTruthy();
    expect(match[1]).toMatch(/background:\s*transparent/);
  });

  test('Bible-panel body fill is still transparent (glass-audit fix, defect 2)', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.bible-panel-body\s*\{([^}]*)\}/);
    expect(match, 'expected a .bible-panel-body rule').toBeTruthy();
    expect(match[1]).toMatch(/background:\s*transparent/);
  });

  // The drag-handle grip glyph (glass-audit fix, defect 3) this used to
  // guard the presence of was deliberately removed by
  // 20260825-reader-dock-rail-polish's item 1 — see
  // Reader.dockGlassAudit.test.jsx's own updated describe block for the
  // "now guards absence" coverage of that removal.

  test('.dv-dockview root transparency (glass-fix defect) is still present', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.dockview-theme-abyss \.dv-dockview\s*\{([^}]*)\}/);
    expect(match, 'expected a .dockview-theme-abyss .dv-dockview rule').toBeTruthy();
    expect(match[1]).toMatch(/background-color:\s*transparent/);
  });
});
