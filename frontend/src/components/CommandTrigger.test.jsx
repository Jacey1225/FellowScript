// Tests for the "Jump or Ask" command-trigger (design-spec §3.2-3.3,
// intake-spec.md's one genuinely new interactive surface in the reader
// restyle pass — see architecture.json step 3 / frontend.json). Covers the
// concrete acceptance criteria from intake-spec.md:
//   - Cmd/Ctrl+K and click both open the overlay
//   - "Jump to passage" mode navigates via the real handleNavigate /
//     handleNavigateVerse handlers (passed in as onNavigate/onNavigateVerse)
//   - "Ask the agent" mode sends a real message through sendAgentMessage,
//     seeding a session via onOpenAgent/onNewAgent per the resolved
//     state-sharing decision in frontend.json / CommandTrigger.jsx
//
// Run with: cd frontend && npm test -- --run src/components/CommandTrigger.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, within, cleanup } from '@testing-library/react';
import CommandTrigger from './CommandTrigger.jsx';

// This project's vitest config runs with `globals: false`, so RTL does not
// auto-register cleanup between tests (see AdminGate.test.jsx et al. for the
// established convention) — required here since antd's Modal renders its
// content into a document.body portal that otherwise leaks across tests.
afterEach(() => cleanup());

const BOOKS = ['Genesis', 'Exodus', 'Matthew', 'Mark']; // NT_FIRST = 'Matthew' -> OT: Genesis/Exodus, NT: Matthew/Mark

// antd's Segmented renders each option's label twice (once for the visible
// item, once for an off-screen sizing measurement), so text queries for its
// option labels must use the *AllBy* variants rather than a single-match
// getByText.
function overlayIsOpen() {
  return screen.queryAllByText('Jump to passage').length > 0;
}

function clickSegmentedOption(label) {
  fireEvent.click(screen.getAllByText(label)[0]);
}

function baseProps(overrides = {}) {
  return {
    books: BOOKS,
    curBook: null,
    curChapter: null,
    chapterCount: (book) => (book === 'Genesis' ? 3 : 2),
    verseCount: (book, ch) => 5,
    onNavigate: vi.fn(),
    onNavigateVerse: vi.fn(),
    user: { user_id: 'u1', username: 'tester' },
    agents: [],
    activeAgent: null,
    agentMessages: [],
    agentThinking: false,
    onOpenAgent: vi.fn(),
    onNewAgent: vi.fn(),
    sendAgentMessage: vi.fn(),
    curVerse: null,
    allNotes: {},
    ...overrides,
  };
}

// jsdom doesn't implement scrollIntoView; AgentChatThread (rendered by the
// overlay's Ask mode) calls it on every message-list update. Same pattern as
// the ResizeObserver stub in Reader.dockview.test.jsx for a jsdom gap.
if (!Element.prototype.scrollIntoView) {
  Element.prototype.scrollIntoView = () => {};
}

describe('CommandTrigger pill', () => {
  test('renders the resting pill with label and ⌘K shortcut chip, overlay closed', () => {
    render(<CommandTrigger {...baseProps()} />);
    const btn = screen.getByRole('button', { name: /Jump or Ask/i });
    expect(btn).toBeTruthy();
    expect(within(btn).getByText('⌘K')).toBeTruthy();
    expect(btn.className).not.toContain('open');
    // Overlay content shouldn't be in the document until opened.
    expect(screen.queryByText('Jump to passage')).toBeFalsy();
  });

  test('clicking the pill opens the overlay with both segmented modes and marks the pill open', () => {
    render(<CommandTrigger {...baseProps()} />);
    const btn = screen.getByRole('button', { name: /Jump or Ask/i });
    fireEvent.click(btn);

    expect(btn.className).toContain('open');
    expect(overlayIsOpen()).toBe(true);
    expect(screen.getAllByText('Ask the agent').length).toBeGreaterThan(0);
  });

  test('Cmd+K (and Ctrl+K) toggle the overlay open and closed', () => {
    render(<CommandTrigger {...baseProps()} />);
    const btn = screen.getByRole('button', { name: /Jump or Ask/i });

    fireEvent.keyDown(window, { key: 'k', metaKey: true });
    expect(overlayIsOpen()).toBe(true);
    expect(btn.className).toContain('open');

    fireEvent.keyDown(window, { key: 'k', metaKey: true });
    // Closed again — the pill's open/active modifier class is the
    // authoritative, synchronous signal of the `open` state (antd's Modal
    // keeps its content mounted-but-hidden through its exit animation, so
    // asserting on portal content presence here would depend on animation
    // timing rather than the actual toggle logic under test).
    expect(btn.className).not.toContain('open');

    fireEvent.keyDown(window, { key: 'k', ctrlKey: true });
    expect(btn.className).toContain('open');
  });
});

describe('CommandTrigger — Jump to passage mode', () => {
  test('selecting a book and chapter, then "Go to chapter", calls onNavigate(book, chapter) and closes the overlay', () => {
    const props = baseProps();
    render(<CommandTrigger {...props} />);
    const btn = screen.getByRole('button', { name: /Jump or Ask/i });
    fireEvent.click(btn);

    // Defaults to Jump mode — pick an Old Testament book.
    fireEvent.click(screen.getByText('Genesis'));
    // Chapter grid should now show chapters 1..3 for Genesis.
    fireEvent.click(screen.getByText('2'));

    const goBtn = screen.getByRole('button', { name: /Go to chapter/i });
    expect(goBtn).not.toBeDisabled();
    fireEvent.click(goBtn);

    expect(props.onNavigate).toHaveBeenCalledWith('Genesis', 2);
    expect(props.onNavigateVerse).not.toHaveBeenCalled();
    // Overlay closes (onDone -> handleClose) after navigating) — see the
    // Cmd+K test above for why this asserts on the pill's class, not portal
    // content presence.
    expect(btn.className).not.toContain('open');
  });

  test('selecting a book, chapter, and verse calls onNavigateVerse(book, chapter, verse) and closes the overlay', () => {
    const props = baseProps();
    render(<CommandTrigger {...props} />);
    const btn = screen.getByRole('button', { name: /Jump or Ask/i });
    fireEvent.click(btn);

    fireEvent.click(screen.getByText('Matthew')); // New Testament book
    fireEvent.click(screen.getByText('1')); // Matthew has 2 chapters per baseProps' chapterCount

    // Verse column now shows verses 1..5 (verseCount = 5).
    const verseButtons = screen.getAllByText('3');
    // '3' also matches a chapter button potentially; pick the one inside the
    // verse column by filtering on the .bib-ch-btn without an 'active' class
    // ambiguity isn't a concern here since the chapter grid for Matthew only
    // has 2 buttons ('1','2') — '3' can only be a verse button.
    expect(verseButtons.length).toBeGreaterThan(0);
    fireEvent.click(verseButtons[0]);

    expect(props.onNavigateVerse).toHaveBeenCalledWith('Matthew', 1, 3);
    expect(props.onNavigate).not.toHaveBeenCalled();
    expect(btn.className).not.toContain('open');
  });

  test('"Go to chapter" is disabled until both a book and chapter are selected', () => {
    render(<CommandTrigger {...baseProps()} />);
    fireEvent.click(screen.getByRole('button', { name: /Jump or Ask/i }));

    // Before any book is picked, the chapter/verse columns show hints, no Go button yet.
    expect(screen.getByText('Select a book')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /Go to chapter/i })).toBeFalsy();

    fireEvent.click(screen.getByRole('button', { name: 'Exodus' }));
    // Now the "Go to chapter" button exists but is disabled without a chapter pick.
    const goBtn = screen.getByRole('button', { name: /Go to chapter/i });
    expect(goBtn).toBeDisabled();
  });

  test('pre-seeds the picker from curBook/curChapter when the overlay is opened mid-reading', () => {
    render(<CommandTrigger {...baseProps({ curBook: 'Exodus', curChapter: 1 })} />);
    fireEvent.click(screen.getByRole('button', { name: /Jump or Ask/i }));

    // Exodus should already be selected (active), showing its chapter grid directly.
    const exodusBtn = screen.getByRole('button', { name: 'Exodus' });
    expect(exodusBtn.className).toContain('active');
    expect(screen.getByText('Exodus 1')).toBeTruthy();
  });
});

describe('CommandTrigger — Ask the agent mode', () => {
  test('switching to Ask mode with no active agent and an existing enabled agent calls onOpenAgent with it', () => {
    const enabledAgent = { id: 'a1', enabled: true };
    const props = baseProps({ agents: [enabledAgent], activeAgent: null });
    render(<CommandTrigger {...props} />);
    fireEvent.click(screen.getByRole('button', { name: /Jump or Ask/i }));

    clickSegmentedOption('Ask the agent');

    expect(props.onOpenAgent).toHaveBeenCalledWith(enabledAgent);
    expect(props.onNewAgent).not.toHaveBeenCalled();
  });

  test('switching to Ask mode with no agents at all calls onNewAgent to create one', () => {
    const props = baseProps({ agents: [], activeAgent: null });
    render(<CommandTrigger {...props} />);
    fireEvent.click(screen.getByRole('button', { name: /Jump or Ask/i }));

    clickSegmentedOption('Ask the agent');

    expect(props.onNewAgent).toHaveBeenCalled();
    expect(props.onOpenAgent).not.toHaveBeenCalled();
  });

  test('does not re-open/re-create an agent when one is already active', () => {
    const activeAgent = { id: 'active-1', enabled: true };
    const props = baseProps({ agents: [activeAgent], activeAgent });
    render(<CommandTrigger {...props} />);
    fireEvent.click(screen.getByRole('button', { name: /Jump or Ask/i }));

    clickSegmentedOption('Ask the agent');

    expect(props.onOpenAgent).not.toHaveBeenCalled();
    expect(props.onNewAgent).not.toHaveBeenCalled();
  });

  test('typing a message and sending in Ask mode calls sendAgentMessage with the real message text', () => {
    const activeAgent = { id: 'active-1', enabled: true };
    const props = baseProps({ agents: [activeAgent], activeAgent });
    render(<CommandTrigger {...props} />);
    fireEvent.click(screen.getByRole('button', { name: /Jump or Ask/i }));
    clickSegmentedOption('Ask the agent');

    const input = screen.getByPlaceholderText('Ask your spiritual guide…');
    fireEvent.change(input, { target: { value: 'What does this verse mean?' } });
    fireEvent.keyDown(input, { key: 'Enter', code: 'Enter' });

    expect(props.sendAgentMessage).toHaveBeenCalledWith('What does this verse mean?');
  });

  test('renders existing agent messages in the thread', () => {
    const activeAgent = { id: 'active-1', enabled: true, name: 'Guide' };
    const props = baseProps({
      agents: [activeAgent],
      activeAgent,
      agentMessages: [{ text: 'Hello there', mine: false, timestamp: new Date().toISOString() }],
    });
    render(<CommandTrigger {...props} />);
    fireEvent.click(screen.getByRole('button', { name: /Jump or Ask/i }));
    clickSegmentedOption('Ask the agent');

    expect(screen.getByText('Hello there')).toBeTruthy();
  });
});
