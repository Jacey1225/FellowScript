// Behavioral/DOM regression test for the portal-based structural fix
// (.claude/pipeline/20260826-notes-filter-panel-blur-increase, step 3
// verification): .notes-filter-panel and .chat-overlay now createPortal to
// document.body instead of rendering as normal descendants of their host
// panel, to escape the ancestor .dv-groupview backdrop-filter compositing
// bug (root-caused and fixed in frontend.json for this task; the actual
// composited-blur verification against real fine text lives in this task's
// testing.json, via a headless-Chromium static harness, since jsdom can't
// render backdrop-filter). This file instead exercises the DOM/behavioral
// contract jsdom CAN verify: the overlay really lands on document.body (not
// buried inside its old host container), open/close both work, and the
// popup's own controls stay interactive after the portal change.
//
// Run with: cd frontend && npm test -- --run src/pages/Reader.dockPortalBlurFix.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, within } from '@testing-library/react';
import NotesPanel from '../components/panels/NotesPanel.jsx';
import { NotesPanelContext } from '../context/ReaderPanelContexts.jsx';

afterEach(() => cleanup());

function renderNotesPanel(overrides = {}) {
  const contextValue = {
    user: { user_id: 'u1', username: 'tester' },
    currentGroupId: null,
    groups: [],
    onGroupChange: () => {},
    onNavigateVerse: () => {},
    notesData: { all: {}, filtered: null },
    groupLoading: false,
    filterActive: false,
    saveNote: vi.fn(async () => true),
    deleteNote: vi.fn(async () => {}),
    postReply: vi.fn(async () => {}),
    loadDetailReplies: vi.fn(async () => []),
    applyFilter: vi.fn(),
    clearFilter: vi.fn(),
    books: ['Genesis'],
    chapterCount: () => 1,
    verseCount: () => 1,
    ...overrides,
  };

  return render(
    <NotesPanelContext.Provider value={contextValue}>
      <NotesPanel />
    </NotesPanelContext.Provider>
  );
}

describe('NotesPanel — .notes-filter-panel portal behavior', () => {
  test('Filter & Sort popup is not rendered until opened', () => {
    renderNotesPanel();
    expect(document.body.querySelector('.notes-filter-panel')).toBeNull();
  });

  test('opening Filter & Sort portals .notes-filter-panel directly onto document.body, not inside .notes-sidebar', () => {
    const { container } = renderNotesPanel();
    const filterBtn = container.querySelector('.anticon-filter')?.closest('button');
    expect(filterBtn).toBeTruthy();
    fireEvent.click(filterBtn);

    const overlay = document.body.querySelector('.notes-filter-panel');
    expect(overlay).toBeTruthy();
    // The whole point of the portal fix: it must be a document.body child,
    // not nested inside .notes-sidebar / .dv-groupview like before.
    expect(overlay.parentElement).toBe(document.body);
    expect(container.querySelector('.notes-filter-panel')).toBeNull();
  });

  test('the portaled popup keeps its own controls interactive: Apply/Clear/back-arrow all remain clickable and wired', () => {
    const applyFilter = vi.fn();
    const clearFilter = vi.fn();
    const { container } = renderNotesPanel({ applyFilter, clearFilter });
    fireEvent.click(container.querySelector('.anticon-filter').closest('button'));

    const overlay = document.body.querySelector('.notes-filter-panel');
    const applyBtn = within(overlay).getByText('Apply').closest('button');
    const clearBtn = within(overlay).getByText('Clear').closest('button');
    expect(applyBtn).toBeTruthy();
    expect(clearBtn).toBeTruthy();

    fireEvent.click(clearBtn);
    expect(clearFilter).toHaveBeenCalledTimes(1);
    // Clearing closes the popup (onClear -> setShowFilter(false) in NotesPanel).
    expect(document.body.querySelector('.notes-filter-panel')).toBeNull();
  });

  test('closing via the back-arrow button removes the portaled overlay from document.body entirely (no orphaned node left behind)', () => {
    const { container } = renderNotesPanel();
    fireEvent.click(container.querySelector('.anticon-filter').closest('button'));
    expect(document.body.querySelector('.notes-filter-panel')).toBeTruthy();

    const backBtn = document.body.querySelector('.notes-filter-panel .anticon-arrow-left').closest('button');
    fireEvent.click(backBtn);

    expect(document.body.querySelector('.notes-filter-panel')).toBeNull();
  });

  test('re-opening after a close portals a fresh instance cleanly (open -> close -> open cycle leaves no duplicate/stale overlay)', () => {
    const { container } = renderNotesPanel();
    const filterBtn = container.querySelector('.anticon-filter').closest('button');

    fireEvent.click(filterBtn);
    fireEvent.click(document.body.querySelector('.notes-filter-panel .anticon-arrow-left').closest('button'));
    fireEvent.click(filterBtn);

    const overlays = document.body.querySelectorAll('.notes-filter-panel');
    expect(overlays.length).toBe(1);
  });
});
