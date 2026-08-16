// Regression test for security audit finding 6 (stored XSS): the note
// editor in NotesPanel.jsx used to assign note.text directly to
// bodyRef.current.innerHTML, bypassing sanitizeNoteHtml() — the same
// sanitizer NoteBody (read-only rendering) already used correctly. This
// proves the editor's mount effect now sanitizes before touching innerHTML,
// by opening the editor on a note whose stored text carries an XSS payload
// and asserting the DOM never contains the raw <script>/onerror payload.
//
// Run with: cd frontend && npm test -- --run src/components/panels/NotesPanel.test.jsx
import React from 'react';
import { describe, test, expect, vi } from 'vitest';
import { render, screen, fireEvent, within } from '@testing-library/react';
import NotesPanel from './NotesPanel.jsx';
import { NotesPanelContext } from '../../context/ReaderPanelContexts.jsx';

const MALICIOUS_NOTE_ID = 'note-xss-1';
const MALICIOUS_TEXT = '<p>hi</p><script>window.__xss_fired__ = true;</script><img src=x onerror="window.__xss_fired__ = true">';

function renderNotesPanel(overrides = {}) {
  const contextValue = {
    user: { user_id: 'u1', username: 'tester' },
    currentGroupId: null,
    groups: [],
    onGroupChange: () => {},
    onNavigateVerse: () => {},
    notesData: {
      all: {
        [MALICIOUS_NOTE_ID]: {
          title: 'Payload note',
          text: MALICIOUS_TEXT,
          public: false,
          verses: [],
          user_id: 'u1',
        },
      },
      filtered: null,
    },
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

// Regression test for the Reader dock structural redesign (design-notes.md
// §6): the Notes sign-in empty state was the one gated/empty state on the
// page without a glyph above its message (unlike the populated-empty state's
// ✦ glyph and AgentChatPanel's RobotOutlined). Proves the glyph renders
// alongside the existing message/CTA rather than replacing them.
describe('NotesPanel sign-in empty state — glyph consistency', () => {
  test('renders a glyph above the sign-in message, alongside the existing message and CTA', () => {
    const { container } = renderNotesPanel({ user: null });

    expect(container.querySelector('.anticon-lock')).toBeTruthy();
    expect(screen.getByText('Sign in to take notes while you read.')).toBeTruthy();
    expect(screen.getByText('Sign In')).toBeTruthy();
  });
});

describe('NotesPanel note editor — XSS sanitization at the innerHTML callsite', () => {
  test('opening the editor on a note with a script/onerror payload never injects an executable element into the DOM', () => {
    window.__xss_fired__ = false;

    const { container } = renderNotesPanel();

    // Open the edit view for the malicious note via its card's edit button.
    const editBtn = container.querySelector('.anticon-edit')?.closest('button');
    expect(editBtn).toBeTruthy();
    fireEvent.click(editBtn);

    // The contentEditable note body should now be mounted with the note's
    // (sanitized) text.
    const body = container.querySelector('.note-body-textarea');
    expect(body).toBeTruthy();

    // The core assertion: no <script> element and no onerror-bearing element
    // ever made it into the live DOM, and the inline handler never executed.
    expect(body.querySelectorAll('script').length).toBe(0);
    expect(body.innerHTML.toLowerCase()).not.toContain('onerror');
    expect(body.innerHTML.toLowerCase()).not.toContain('<img');
    expect(window.__xss_fired__).toBe(false);

    // Legitimate content is preserved.
    expect(body.textContent).toContain('hi');
  });
});
