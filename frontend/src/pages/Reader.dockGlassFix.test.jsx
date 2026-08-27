// Regression test for the "dockable glass" live-render fixes
// (.claude/pipeline/20260825-dockable-glass-fix): a prior implementation
// pass left reader-dock.css's panel-level glass rules (.dv-groupview
// background + backdrop-filter) looking spec-conformant in isolation, but
// the live render still showed an opaque black area behind/around the
// docked panels with a hard cutoff at the header's bottom edge, and the
// panels themselves read as flat/opaque rather than frosted glass.
//
// Root cause: dockview-core ships its own theme-unscoped base rule,
// `.dv-dockview { background-color: var(--dv-group-view-background-color) }`
// (dockview-core/dist/styles/dockview.css), on the single root wrapper
// DockviewReact renders inside .reader-dock-container -- the ancestor of
// every panel and every gutter between them. For the abyss theme that
// variable resolves to --dv-color-abyss-dark, an intentionally opaque
// #050505 (used elsewhere for legitimately-opaque abyss chrome). That
// opaque fill sat directly between the fixed ambient-glow layers and every
// panel, and directly behind .dv-groupview's own already-correct
// translucent backdrop-filter -- so the blur was compositing that opaque
// fill, not the ambient glow.
//
// This is a source-guard test (following the existing pattern in
// Reader.dockview.test.jsx) rather than a computed-style assertion, since
// jsdom doesn't implement backdrop-filter/paint-order well enough to assert
// the actual visual fix; it guards against silently regressing the override
// rule itself, plus the typography conformance fixes (defect 3) landing in
// the same task.
//
// Run with: cd frontend && npm test -- --run src/pages/Reader.dockGlassFix.test.jsx
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { describe, test, expect } from 'vitest';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function readStripped(relPath) {
  const raw = fs.readFileSync(path.join(__dirname, relPath), 'utf8');
  return raw.replace(/\/\*[\s\S]*?\*\//g, '');
}

describe('reader-dock.css — .dv-dockview transparency fix (opaque-backdrop regression guard)', () => {
  test('overrides dockview-core\'s theme-unscoped .dv-dockview opaque background to transparent, scoped to the abyss theme', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/([^{}]+)\{\s*background-color:\s*transparent;?\s*\}/);
    expect(match, 'expected a rule setting background-color: transparent in reader-dock.css').toBeTruthy();
    const selector = match[1].trim();
    expect(selector).toBe('.dockview-theme-abyss .dv-dockview');
  });

  test('.dv-groupview (panel body) glass treatment — translucent fill + blur — is still present, not accidentally removed', () => {
    const css = readStripped('../styles/reader-dock.css');
    expect(css).toMatch(/\.dockview-theme-abyss \.dv-groupview\s*\{[^}]*background:\s*var\(--panel-glass-bg\)/);
    expect(css).toMatch(/\.dockview-theme-abyss \.dv-groupview\s*\{[^}]*backdrop-filter:\s*blur\(var\(--panel-glass-blur\)\)/);
  });

  test('dockview tab labels use Inter (design tokens §4.3 "chrome labels" row), not Space Grotesk', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.dockview-theme-abyss \.dv-default-tab,\s*\n\.dockview-theme-abyss \.dv-default-tab-content\s*\{([^}]*)\}/);
    expect(match, 'expected the .dv-default-tab font rule block').toBeTruthy();
    expect(match[1]).toMatch(/font-family:\s*'Inter'/);
    expect(match[1]).not.toMatch(/Space Grotesk/);
  });
});

describe('index.html — required webfonts are actually loaded (defect 3)', () => {
  test('Google Fonts link includes Cormorant Garamond and Source Serif 4', () => {
    const html = fs.readFileSync(path.join(__dirname, '../../index.html'), 'utf8');
    const linkMatch = html.match(/<link href="https:\/\/fonts\.googleapis\.com\/css2\?[^"]*" rel="stylesheet" \/>/);
    expect(linkMatch, 'expected the Google Fonts <link> in index.html').toBeTruthy();
    const href = linkMatch[0];
    expect(href).toMatch(/family=Cormorant\+Garamond/);
    expect(href).toMatch(/family=Source\+Serif\+4/);
  });
});

describe('global.css — typography conformance (design tokens §4.3, ground-truth specs govern over the request\'s shorthand)', () => {
  test('.nav-logo (wordmark) uses Cormorant Garamond, not Playfair Display', () => {
    const css = readStripped('../styles/global.css');
    const match = css.match(/\.nav-logo\s*\{([^}]*)\}/);
    expect(match, 'expected a .nav-logo rule').toBeTruthy();
    expect(match[1]).toMatch(/font-family:\s*'Cormorant Garamond'/);
  });

  test('.card-title (the "Chapter {N}" numeral) uses Cormorant Garamond, not Spectral', () => {
    const css = readStripped('../styles/global.css');
    const match = css.match(/\.card-title\s*\{([^}]*)\}/);
    expect(match, 'expected a .card-title rule').toBeTruthy();
    expect(match[1]).toMatch(/font-family:\s*'Cormorant Garamond'/);
  });

  test('.card-body (scripture reading text) uses Source Serif 4 with a Libre Baskerville fallback, per the ground-truth spec -- not Inter, not Spectral', () => {
    const css = readStripped('../styles/global.css');
    const match = css.match(/\.card-body\s*\{([^}]*)\}/);
    expect(match, 'expected a .card-body rule').toBeTruthy();
    expect(match[1]).toMatch(/font-family:\s*'Source Serif 4',\s*'Libre Baskerville'/);
  });

  test('.card-section-head / .section-head (a distinct italic-caption role not named in the ground-truth typography table) are left unchanged on Spectral, not blanket-converted', () => {
    const css = readStripped('../styles/global.css');
    const sectionHead = css.match(/\.card-section-head\s*\{([^}]*)\}/);
    const inlineSectionHead = css.match(/\n\.section-head\s*\{([^}]*)\}/);
    expect(sectionHead, 'expected a .card-section-head rule').toBeTruthy();
    expect(inlineSectionHead, 'expected a .section-head rule').toBeTruthy();
    expect(sectionHead[1]).toMatch(/font-family:\s*'Spectral'/);
    expect(inlineSectionHead[1]).toMatch(/font-family:\s*'Spectral'/);
  });
});
