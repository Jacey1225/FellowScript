// Regression test for the notes-panel-glass-toolbar fix
// (.claude/pipeline/20260826-notes-panel-glass-toolbar): the Notes panel's
// "Filter & Sort" popup (FilterPanel, inline in NotesPanel.jsx) used a flat
// opaque rgba(6,4,1,0.98) fill with no blur, and the toolbar row rendered the
// filter/funnel button between the "Personal" group selector and "+ New"
// instead of leftmost.
//
// This is a source-guard test (same pattern as Reader.dockGlassFix.test.jsx /
// Reader.dockVerseMessagesGlass.test.jsx), since jsdom doesn't implement
// backdrop-filter compositing well enough to assert the actual composited
// look. Live-render verification (computed styles + screenshots via headless
// Chromium, in both light and dark theme, against the real .dv-groupview /
// .notes-sidebar / .notes-filter-panel DOM+CSS) was done separately and is
// recorded in this task's testing.json, not here.
//
// Run with: cd frontend && npm test -- --run src/pages/Reader.dockNotesGlassToolbar.test.jsx
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { describe, test, expect } from 'vitest';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function readStripped(relPath) {
  const raw = fs.readFileSync(path.join(__dirname, relPath), 'utf8');
  return raw.replace(/\/\*[\s\S]*?\*\//g, '');
}

describe('reader-dock.css — .notes-filter-panel (Notes "Filter & Sort" popup) glass restyle', () => {
  test('.notes-filter-panel exists and uses a translucent+blurred fill, not the old opaque rgba(6,4,1,0.98) flat fill', () => {
    const css = readStripped('../styles/reader-dock.css');
    const match = css.match(/\.notes-filter-panel\s*\{([^}]*)\}/);
    expect(match, 'expected a .notes-filter-panel rule').toBeTruthy();
    const body = match[1];
    expect(body).not.toMatch(/rgba\(6,\s*4,\s*1,\s*0\.98\)/);
    expect(body).toMatch(/background:\s*rgba\(20,14,9,0\.4\)/);
    expect(body).toMatch(/backdrop-filter:\s*blur\(10px\)\s*saturate\(150%\)/);
  });

  test('.notes-filter-panel blur (10px) is lighter than its .dv-groupview panel ancestor blur (16px), per the "nested glass gets a lighter blur than its parent" rule', () => {
    const css = readStripped('../styles/reader-dock.css');
    expect(css).toMatch(/--panel-glass-blur:\s*16px/);
    const match = css.match(/\.notes-filter-panel\s*\{([^}]*)\}/);
    const panelBlur = parseInt(css.match(/--panel-glass-blur:\s*(\d+)px/)[1], 10);
    const filterBlur = parseInt(match[1].match(/backdrop-filter:\s*blur\((\d+)px\)/)[1], 10);
    expect(filterBlur).toBeLessThan(panelBlur);
  });

  test('.notes-filter-panel reuses the same values as .chat-overlay (established nested-overlay precedent) rather than inventing new unrelated-palette numbers', () => {
    const cssDock = readStripped('../styles/reader-dock.css');
    const cssGlobal = readStripped('../styles/global.css');
    const filterMatch = cssDock.match(/\.notes-filter-panel\s*\{([^}]*)\}/)[1];
    const overlayMatch = cssGlobal.match(/\.chat-overlay\s*\{([^}]*)\}/)[1];
    const bg = /background:\s*(rgba\([^)]*\))/;
    const blur = /backdrop-filter:\s*(blur\([^)]*\)\s*saturate\([^)]*\))/;
    expect(filterMatch.match(bg)[1]).toBe(overlayMatch.match(bg)[1]);
    expect(filterMatch.match(blur)[1]).toBe(overlayMatch.match(blur)[1]);
  });
});

describe('NotesPanel.jsx — FilterPanel component', () => {
  test('FilterPanel root no longer sets an inline opaque rgba(6,4,1,0.98) background, and instead relies on the .notes-filter-panel CSS class', () => {
    // FilterPanel moved out of NotesPanel.jsx into its own file (readability
    // #10, 20260904-frontend-arch-sweep) -- same component, same behavior,
    // reorganized location.
    const src = fs.readFileSync(path.join(__dirname, '../components/panels/notes/FilterPanel.jsx'), 'utf8');
    const match = src.match(/function FilterPanel\([^)]*\)\s*\{[\s\S]*?\n\}/);
    expect(match, 'expected a FilterPanel function').toBeTruthy();
    const body = match[0];
    expect(body).not.toMatch(/rgba\(6,\s*4,\s*1,\s*0\.98\)/);
    expect(body).toMatch(/className="notes-filter-panel"/);
  });
});

describe('NotesPanel.jsx — toolbar reorder', () => {
  test('the toolbar row renders the filter Button before {groupSelector} before the "+ New" Button (filter leftmost)', () => {
    const src = fs.readFileSync(path.join(__dirname, '../components/panels/NotesPanel.jsx'), 'utf8');
    // Isolate the toolbar wrapper div (the header row's right-hand control
    // group, identified by its gap:4 / alignItems:center inline style).
    const toolbarMatch = src.match(/<div style=\{\{ display: 'flex', gap: 4, alignItems: 'center' \}\}>([\s\S]*?)<\/div>\s*<\/div>/);
    expect(toolbarMatch, 'expected to find the toolbar wrapper div').toBeTruthy();
    const toolbar = toolbarMatch[1];

    const filterIdx = toolbar.indexOf('FilterOutlined');
    const groupIdx  = toolbar.indexOf('{groupSelector}');
    const newIdx    = toolbar.indexOf('PlusOutlined'); // unique to the "+ New" button; a leading JSX comment also mentions the word "New" in prose, so a bare "New" substring search would false-positive on the comment.

    expect(filterIdx).toBeGreaterThan(-1);
    expect(groupIdx).toBeGreaterThan(-1);
    expect(newIdx).toBeGreaterThan(-1);
    expect(filterIdx).toBeLessThan(groupIdx);
    expect(groupIdx).toBeLessThan(newIdx);
  });

  test('the filter Button itself is untouched (icon, onClick, active-color logic) -- pure reordering, not a restyle', () => {
    const src = fs.readFileSync(path.join(__dirname, '../components/panels/NotesPanel.jsx'), 'utf8');
    expect(src).toMatch(/icon=\{<FilterOutlined \/>\}\s*\n\s*onClick=\{\(\) => setShowFilter\(true\)\}/);
    expect(src).toMatch(/color: filterActive \? 'var\(--gold\)' : 'rgba\(255,198,26,0\.55\)'/);
  });
});

describe('NotesPanel.jsx — main viewing panel background (no Notes-specific opaque override)', () => {
  test('.notes-sidebar and .note-editor-body declare no background of their own in global.css, so the panel\'s painted surface is the .dv-groupview glass fill (confirmed live separately in testing.json)', () => {
    const css = readStripped('../styles/global.css');
    const sidebarMatch = css.match(/\n\.notes-sidebar\s*\{([^}]*)\}/);
    expect(sidebarMatch, 'expected a .notes-sidebar rule').toBeTruthy();
    expect(sidebarMatch[1]).not.toMatch(/background/);
  });

  test('NoteDetail\'s own root wrapper div carries no inline background style (only its nested verse-tag buttons/replies do, which is unrelated and unchanged)', () => {
    // NoteDetail moved out of NotesPanel.jsx into its own file (readability
    // #10, 20260904-frontend-arch-sweep) -- same component, same behavior,
    // reorganized location.
    const src = fs.readFileSync(path.join(__dirname, '../components/panels/notes/NoteDetail.jsx'), 'utf8');
    // Check the *root* wrapper div's own style object specifically, not the
    // whole function body (which legitimately contains unrelated
    // `background:` on nested verse-tag buttons/reply blocks).
    const rootDivMatch = src.match(/function NoteDetail\([\s\S]*?return \(\s*<div style=\{\{([^}]*)\}\}>/);
    expect(rootDivMatch, 'expected NoteDetail\'s root <div style={{...}}> ').toBeTruthy();
    expect(rootDivMatch[1]).not.toMatch(/background/);
  });
});

describe('NotesPanel.jsx — no functional regression from the presentation-only changes', () => {
  test('FilterPanel still exposes onApply/onClear/onClose with unchanged sort/filter state wiring', () => {
    // FilterPanel moved out of NotesPanel.jsx into its own file (readability
    // #10, 20260904-frontend-arch-sweep) -- same component, same behavior,
    // reorganized location.
    const src = fs.readFileSync(path.join(__dirname, '../components/panels/notes/FilterPanel.jsx'), 'utf8');
    expect(src).toMatch(/function FilterPanel\(\{ onApply, onClear, onClose, groupUsernames \}\)/);
    expect(src).toMatch(/onClick=\{\(\) => onApply\(\{ sortVal, filterType, filterVal \}\)\}/);
    expect(src).toMatch(/onClick=\{\(\) => \{ setSortVal\(''\); setFilterType\(''\); setFilterVal\(''\); onClear\(\); \}\}/);
  });

  test('NotesPanel still wires save/delete/reply/group-change/verse-navigation handlers unchanged', () => {
    const src = fs.readFileSync(path.join(__dirname, '../components/panels/NotesPanel.jsx'), 'utf8');
    expect(src).toMatch(/saveNote,\s*deleteNote,\s*postReply,\s*loadDetailReplies/);
    expect(src).toMatch(/applyFilter,\s*clearFilter/);
    expect(src).toMatch(/onGroupChange/);
    expect(src).toMatch(/onNavigateVerse/);
  });
});
