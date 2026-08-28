// Tests for ChatThread.jsx -- covers the visual cleanup made in
// .claude/pipeline/20260828-chat-schedule-ui-cleanup: the divider between
// the messages area and the text input/send bar was removed, while the
// header's own divider (above the messages area) is untouched. Also covers
// the pre-existing send-message behavior to guard against functional
// regression, per this task's acceptance criterion 8.
//
// No dedicated test file existed for this component before this task.
//
// Run with: cd frontend && npm test -- --run src/components/ChatThread.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeAll, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import ChatThread from './ChatThread.jsx';

// jsdom doesn't implement scrollIntoView, which ChatThread calls on every
// messages-change to auto-scroll the transcript -- without this polyfill,
// mounting the component throws in the passive-effect phase.
beforeAll(() => {
  if (!Element.prototype.scrollIntoView) {
    Element.prototype.scrollIntoView = () => {};
  }
});

const CONTACT = { id: 'c1', name: 'Ada Lovelace', type: 'friend' };
const USER = { user_id: 'u1', username: 'me' };

function renderThread(props = {}) {
  const onSend = vi.fn();
  const onBack = vi.fn();
  const onOpenSessionCreator = vi.fn();
  const utils = render(
    <ChatThread
      contact={CONTACT}
      messages={[]}
      groupMembers={[]}
      user={USER}
      onBack={onBack}
      onSend={onSend}
      sessions={[]}
      activeSessionId={null}
      talkingUserId={null}
      onJoinSession={vi.fn()}
      onLeaveSession={vi.fn()}
      onOpenSessionCreator={onOpenSessionCreator}
      onEditSession={vi.fn()}
      onDeleteSession={vi.fn()}
      onNavigateVerse={vi.fn()}
      videoEnabled={false}
      videoTiles={{}}
      onToggleVideo={vi.fn()}
      bindVideoTile={vi.fn()}
      {...props}
    />
  );
  return { onSend, onBack, onOpenSessionCreator, ...utils };
}

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe('ChatThread — input-row divider removed, header divider untouched', () => {
  test('the input/send row no longer has a top border', () => {
    renderThread();
    const input = screen.getByPlaceholderText('Message…');
    const inputRow = input.closest('div');
    expect(inputRow.style.borderTop).toBe('');
  });

  test('the header still has its own bottom border (unaffected by the input-row divider removal)', () => {
    renderThread();
    const headerText = screen.getByText('Ada Lovelace');
    // Header row is the nearest ancestor <div> -- the flex container holding
    // the back button, name, and "+ Session" button.
    const headerRow = headerText.closest('div');
    // jsdom normalizes rgba() spacing when parsing the inline style string.
    expect(headerRow.style.borderBottom).toBe('1px solid rgba(255, 255, 255, 0.09)');
  });
});

describe('ChatThread — send behavior (functional regression guard)', () => {
  test('typing a message and pressing Enter calls onSend with the trimmed text and clears the input', () => {
    const { onSend } = renderThread();
    const input = screen.getByPlaceholderText('Message…');
    fireEvent.change(input, { target: { value: '  hello there  ' } });
    fireEvent.keyDown(input, { key: 'Enter', code: 'Enter' });
    expect(onSend).toHaveBeenCalledWith('hello there');
    expect(input.value).toBe('');
  });

  test('clicking the send button calls onSend; the button is disabled when the input is empty', () => {
    const { onSend } = renderThread();
    const input = screen.getByPlaceholderText('Message…');
    const sendBtn = input.parentElement.querySelector('button');
    expect(sendBtn).toBeDisabled();

    fireEvent.change(input, { target: { value: 'hi' } });
    expect(sendBtn).not.toBeDisabled();
    fireEvent.click(sendBtn);
    expect(onSend).toHaveBeenCalledWith('hi');
  });

  test('renders sent and received message bubbles', () => {
    renderThread({
      messages: [
        { text: 'hi there', mine: true },
        { text: 'hello back', mine: false, sender: 'Ada' },
      ],
    });
    expect(screen.getByText('hi there')).toBeInTheDocument();
    expect(screen.getByText('hello back')).toBeInTheDocument();
    expect(screen.getByText('Ada')).toBeInTheDocument();
  });

  test('the "+ Session" header button calls onOpenSessionCreator', () => {
    const { onOpenSessionCreator } = renderThread();
    fireEvent.click(screen.getByText('+ Session'));
    expect(onOpenSessionCreator).toHaveBeenCalledTimes(1);
  });
});
