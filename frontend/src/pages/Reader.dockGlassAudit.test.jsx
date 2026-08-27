// Regression test for the dockable-glass-audit follow-up
// (.claude/pipeline/20260825-dockable-glass-audit): a second corrective pass
// on top of 20260825-dockable-glass-fix (covered by Reader.dockGlassFix.test.jsx)
// that removed two remaining flat/opaque grey surfaces and added a drag-handle
// grip glyph to each dockview tab.
//
// This is a source-guard test (same pattern as Reader.dockGlassFix.test.jsx),
// since jsdom doesn't implement backdrop-filter/::before rendering well enough
// to assert the actual composited look. Live-render verification (computed
// styles + screenshots via headless Chromium against the running dev server)
// was done separately and is recorded in this task's testing.json, not here.
//
// Run with: cd frontend && npm test -- --run src/pages/Reader.dockGlassAudit.test.jsx
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { describe, test, expect } from 'vitest';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function readStripped(relPath) {
  const raw = fs.readFileSync(path.join(__dirname, relPath), 'utf8');
  return raw.replace(/\/\*[\s\S]*?\*\//g, '');
}

describe('reader-dock.css — tab-strip grey fill removed (defect 1)', () => {
  test('.dv-tabs-and-actions-container no longer paints the opaque --card-bg-2 wash', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.dockview-theme-abyss \.dv-tabs-and-actions-container\s*\{([^}]*)\}/);
    expect(match, 'expected a .dv-tabs-and-actions-container rule').toBeTruthy();
    expect(match[1]).toMatch(/background:\s*transparent/);
    expect(match[1]).not.toMatch(/var\(--card-bg-2\)/);
  });

  test('.dv-groupview glass treatment (translucent fill + blur) is unaffected by the tab-strip fix', () => {
    const css = readStripped('../styles/reader-dock.css');
    expect(css).toMatch(/\.dockview-theme-abyss \.dv-groupview\s*\{[^}]*background:\s*var\(--panel-glass-bg\)/);
    expect(css).toMatch(/\.dockview-theme-abyss \.dv-groupview\s*\{[^}]*backdrop-filter:\s*blur\(var\(--panel-glass-blur\)\)/);
  });
});

describe('reader-dock.css — Bible-panel grey fills removed (defect 2)', () => {
  test('.bible-panel-body no longer paints the opaque --card-bg fill', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.bible-panel-body\s*\{([^}]*)\}/);
    expect(match, 'expected a .bible-panel-body rule').toBeTruthy();
    expect(match[1]).toMatch(/background:\s*transparent/);
    expect(match[1]).not.toMatch(/var\(--card-bg\)[^-]/);
  });

  test('.bible-panel-body .chapter-card is scoped-overridden to transparent (desktop only, not global.css)', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.bible-panel-body \.chapter-card\s*\{([^}]*)\}/);
    expect(match, 'expected a .bible-panel-body .chapter-card scoped override in reader-dock.css').toBeTruthy();
    expect(match[1]).toMatch(/background:\s*transparent/);
  });

  test('global.css\'s shared .chapter-card rule is untouched (mobile branch must keep its opaque framed-page treatment)', () => {
    const css = readStripped('../styles/global.css');
    const match = css.match(/\.chapter-card\s*\{([^}]*)\}/);
    expect(match, 'expected a .chapter-card rule in global.css').toBeTruthy();
    expect(match[1]).toMatch(/background:\s*var\(--card-bg-2\)/);
  });
});

describe('reader-dock.css — drag-handle grip glyph removed from each tab (20260825-reader-dock-rail-polish, item 1)', () => {
  // The 3x3 dot-grid glyph this describe block used to guard the presence
  // of (defect 3 of 20260825-dockable-glass-audit) was deliberately removed
  // by 20260825-reader-dock-rail-polish's item 1 (purely decorative,
  // pointer-events:none, so removal doesn't touch the actual drag surface —
  // see reader-dock.css's own removal-rationale comment). These assertions
  // now guard the opposite: that the glyph and its position:relative
  // companion rule both stay gone.
  test('.dv-tab::before glyph rule is gone', () => {
    const css = readStripped('../styles/reader-dock.css');
    expect(css).not.toMatch(/\.dockview-theme-abyss \.dv-tab::before\s*\{/);
  });

  test('the position:relative companion rule (added solely to anchor the glyph) is gone', () => {
    const css = readStripped('../styles/reader-dock.css');
    const blocks = [...css.matchAll(/\.dockview-theme-abyss \.dv-tab\s*\{([^}]*)\}/g)];
    expect(blocks.some((m) => /position:\s*relative/.test(m[1]))).toBe(false);
  });
});
