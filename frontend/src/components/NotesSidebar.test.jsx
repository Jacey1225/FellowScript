// Regression test for security audit finding 6 (stored XSS): NotesSidebar.jsx
// (the legacy/standalone notes sidebar, used alongside NotesPanel.jsx's
// dockview-panel version) used to assign note.text directly to
// bodyRef.current.innerHTML in its note editor, bypassing sanitizeNoteHtml().
// This proves the editor mount effect now sanitizes before touching
// innerHTML, using the same malicious payload class as the finding
// (script tag + onerror-bearing <img>).
//
// Run with: cd frontend && npm test -- --run src/components/NotesSidebar.test.jsx
import React from 'react';
import { describe, test, expect, vi } from 'vitest';
import { render, fireEvent } from '@testing-library/react';
import NotesSidebar from './NotesSidebar.jsx';

const MALICIOUS_NOTE_ID = 'note-xss-1';
const MALICIOUS_TEXT = '<p>hi</p><script>window.__xss_fired__ = true;</script><img src=x onerror="window.__xss_fired__ = true">';

function baseProps(overrides = {}) {
  return {
    user: { user_id: 'u1', username: 'tester' },
    notes: {
      all: {
        [MALICIOUS_NOTE_ID]: {
          title: 'Payload note',
          text: MALICIOUS_TEXT,
          public: false,
          verses: [],
          user_id: 'u1',
        },
      },
    },
    curBook: 'Genesis', curChapter: 1, curVerse: 1,
    groups: [], currentGroupId: null, onGroupChange: () => {},
    onSaveNote: vi.fn(async () => true),
    onDeleteNote: vi.fn(async () => {}),
    onReply: vi.fn(async () => {}),
    onLoadReplies: vi.fn(async () => []),
    applyFilter: vi.fn(), clearFilter: vi.fn(), filterActive: false,
    allNotes: {}, groupNotes: {}, groupLoading: false,
    books: ['Genesis'], chapterCount: () => 1, verseCount: () => 1,
    localHl: [], groupHighlights: [], groupUsernames: {},
    onNavigateVerse: () => {},
    initialTab: 'verse',
    ...overrides,
  };
}

describe('NotesSidebar note editor — XSS sanitization at the innerHTML callsite', () => {
  test('opening the editor on a note with a script/onerror payload never injects an executable element into the DOM', () => {
    window.__xss_fired__ = false;

    const { container } = render(<NotesSidebar {...baseProps()} />);

    const editBtn = container.querySelector('.anticon-edit')?.closest('button');
    expect(editBtn).toBeTruthy();
    fireEvent.click(editBtn);

    const body = container.querySelector('.note-body-textarea');
    expect(body).toBeTruthy();

    expect(body.querySelectorAll('script').length).toBe(0);
    expect(body.innerHTML.toLowerCase()).not.toContain('onerror');
    expect(body.innerHTML.toLowerCase()).not.toContain('<img');
    expect(window.__xss_fired__).toBe(false);
    expect(body.textContent).toContain('hi');
  });
});
