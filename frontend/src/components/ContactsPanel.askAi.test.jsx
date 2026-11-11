// Task 20261106-remove-agents-ask-ai (testing step 8): ContactsPanel "Ask AI"
// section (flag ask_ai_default_agent). Flag on = `askAi` prop present: the
// Agents section is replaced by an "Ask AI" chat list; flag off = no `askAi`
// prop and the legacy Agents section renders unchanged. A failed refresh keeps
// the shown list (throw-not-fabricate / preserve-cache-on-failed-refresh).
//
// Run with: cd frontend && npm test -- --run src/components/ContactsPanel.askAi.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';

// localStorage-backed hook and capability fetch are irrelevant here.
vi.mock('../hooks/useCollapsedSections.js', () => ({
  useCollapsedSections: () => [{}, vi.fn()],
}));
vi.mock('../hooks/useCapabilities.js', () => ({ useCapabilities: () => ({}) }));

import ContactsPanel from './ContactsPanel.jsx';

afterEach(cleanup);

const baseProps = () => ({
  user: { user_id: 'u1' },
  friends: [], groups: [], currentContact: null,
  onOpen: vi.fn(), onAddFriend: vi.fn(), onRemoveFriend: vi.fn(), onReportUser: vi.fn(),
  onBlockUser: vi.fn(), onCreateGroup: vi.fn(), onUpdateGroup: vi.fn(), onLeaveGroup: vi.fn(),
  loaded: true, onLoad: vi.fn(),
  agents: [], activeAgent: null, onOpenAgent: vi.fn(), onNewAgent: vi.fn(),
});

const askAiProps = (over = {}) => ({
  chats: [], loading: false, error: null, creating: false, createError: null, activeChatId: null,
  onOpenChat: vi.fn(), onNewChat: vi.fn(), onRefresh: vi.fn(), onClearCreateError: vi.fn(),
  ...over,
});

describe('ContactsPanel Ask AI section', () => {
  test('flag on: "Ask AI" header replaces "Agents"; rows show titles, newest activity first', () => {
    const askAi = askAiProps({
      chats: [
        { id: 'old', title: 'Psalm 23', last_message_at: '2026-01-01T10:00:00' },
        { id: 'new', title: 'John 1', last_message_at: '2026-11-01T10:00:00' },
      ],
    });
    render(<ContactsPanel {...baseProps()} askAi={askAi} agents={[{ id: 'a1', name: 'Legacy Agent', enabled: true }]} />);
    expect(screen.getByText('Ask AI')).toBeTruthy();
    expect(screen.queryByText('Agents')).toBeNull();
    expect(screen.queryByText('Legacy Agent')).toBeNull();
    const rows = screen.getAllByRole('button').filter(b => /John 1|Psalm 23/.test(b.textContent));
    expect(rows.map(r => (r.textContent.match(/John 1|Psalm 23/) || [])[0])).toEqual(['John 1', 'Psalm 23']);
  });

  test('clicking a chat row opens that chat; "+" starts a new AI chat', () => {
    const askAi = askAiProps({ chats: [{ id: 'c1', title: 'John 1', last_message_at: '2026-11-01T10:00:00' }] });
    render(<ContactsPanel {...baseProps()} askAi={askAi} />);
    fireEvent.click(screen.getByText('John 1'));
    expect(askAi.onOpenChat).toHaveBeenCalledWith('c1');
    fireEvent.click(screen.getByLabelText('New AI chat'));
    expect(askAi.onNewChat).toHaveBeenCalledTimes(1);
  });

  test('empty list shows "No AI chats yet." with a Start a chat action', () => {
    const askAi = askAiProps();
    render(<ContactsPanel {...baseProps()} askAi={askAi} />);
    expect(screen.getByText('No AI chats yet.')).toBeTruthy();
    fireEvent.click(screen.getByText('Start a chat'));
    expect(askAi.onNewChat).toHaveBeenCalledTimes(1);
  });

  test('failed first load with no saved list: error + Retry, nothing invented', () => {
    const askAi = askAiProps({ error: 'boom' });
    render(<ContactsPanel {...baseProps()} askAi={askAi} />);
    expect(screen.getByText("Couldn't load your chats.")).toBeTruthy();
    expect(screen.queryByText('No AI chats yet.')).toBeNull();
    fireEvent.click(screen.getByText('Retry'));
    expect(askAi.onRefresh).toHaveBeenCalledTimes(1);
  });

  test('failed refresh keeps the saved list on screen and offers Retry', () => {
    const askAi = askAiProps({
      error: 'boom',
      chats: [{ id: 'c1', title: 'Saved chat', last_message_at: '2026-11-01T10:00:00' }],
    });
    render(<ContactsPanel {...baseProps()} askAi={askAi} />);
    expect(screen.getByText('Saved chat')).toBeTruthy();
    expect(screen.getByText("Couldn't refresh. Showing saved chats.")).toBeTruthy();
    expect(screen.queryByText("Couldn't load your chats.")).toBeNull();
    fireEvent.click(screen.getByText('Retry'));
    expect(askAi.onRefresh).toHaveBeenCalledTimes(1);
  });

  test('flag off (no askAi prop): legacy Agents section is unchanged', () => {
    render(<ContactsPanel {...baseProps()} agents={[{ id: 'a1', name: 'Legacy Agent', enabled: true }]} />);
    expect(screen.getByText('Agents')).toBeTruthy();
    expect(screen.getByText('Legacy Agent')).toBeTruthy();
    expect(screen.queryByText('Ask AI')).toBeNull();
  });

  test('flag off: empty agents keeps the legacy empty copy', () => {
    render(<ContactsPanel {...baseProps()} />);
    expect(screen.getByText('No agent chats yet')).toBeTruthy();
  });
});
