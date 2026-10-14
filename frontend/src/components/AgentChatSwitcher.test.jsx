// Chats popover for the Agent Chat dock. Run: cd frontend && npx vitest run src/components/AgentChatSwitcher.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import AgentChatSwitcher from './AgentChatSwitcher.jsx';

const CHATS = [
  { id: 'c1', title: 'Grace talk', created_at: '2026-10-01T00:00:00Z', last_message_at: '2026-10-02T12:00:00Z' },
  { id: 'c2', title: '', created_at: '2026-09-01T00:00:00Z', last_message_at: null },
];

function ui(over = {}) {
  return {
    chats: CHATS, chatsLoading: false, chatsError: null, activeChatId: 'c1', creatingChat: false,
    onSelectChat: vi.fn(), onCreateChat: vi.fn().mockResolvedValue({ id: 'n' }), onRefreshChats: vi.fn(),
    ...over,
  };
}
const openList = () => fireEvent.click(screen.getByRole('button', { name: 'Chats with Mentor' }));

afterEach(() => cleanup());
beforeEach(() => {
  window.ResizeObserver = window.ResizeObserver || class { observe() {} unobserve() {} disconnect() {} };
});

describe('AgentChatSwitcher', () => {
  test('opening refreshes and lists chats with active marked selected', async () => {
    const chatUi = ui();
    render(<AgentChatSwitcher chatUi={chatUi} agentName="Mentor" />);
    openList();
    expect(chatUi.onRefreshChats).toHaveBeenCalled();
    const opts = await screen.findAllByRole('option');
    expect(opts).toHaveLength(2);
    expect(opts[0]).toHaveAttribute('aria-selected', 'true');
    expect(opts[1]).toHaveAttribute('aria-selected', 'false');
    expect(screen.getByText('Grace talk')).toBeInTheDocument();
    expect(screen.getByText('New chat', { selector: 'div' })).toBeInTheDocument(); // untitled row label
  });

  test('clicking a row selects that chat', async () => {
    const chatUi = ui();
    render(<AgentChatSwitcher chatUi={chatUi} agentName="Mentor" />);
    openList();
    fireEvent.click(await screen.findByText('Grace talk'));
    expect(chatUi.onSelectChat).toHaveBeenCalledWith('c1');
  });

  test('icon New chat button calls create', () => {
    const chatUi = ui();
    render(<AgentChatSwitcher chatUi={chatUi} agentName="Mentor" />);
    fireEvent.click(screen.getByRole('button', { name: 'New chat with Mentor' }));
    expect(chatUi.onCreateChat).toHaveBeenCalled();
  });

  test('empty list shows no-chats state, not fabricated rows', async () => {
    render(<AgentChatSwitcher chatUi={ui({ chats: [], activeChatId: null })} agentName="Mentor" />);
    openList();
    expect(await screen.findByText('No chats yet')).toBeInTheDocument();
    expect(screen.queryAllByRole('option')).toHaveLength(0);
  });

  test('load error with no chats shows retry', async () => {
    const chatUi = ui({ chats: [], chatsError: "Couldn't load chats", activeChatId: null });
    render(<AgentChatSwitcher chatUi={chatUi} agentName="Mentor" />);
    openList();
    expect(await screen.findByRole('alert')).toHaveTextContent("Couldn't load chats");
    fireEvent.click(screen.getByRole('button', { name: /try again/i }));
    expect(chatUi.onRefreshChats).toHaveBeenCalled();
  });

  test('refresh error with existing chats keeps the list visible', async () => {
    render(<AgentChatSwitcher chatUi={ui({ chatsError: "Couldn't load chats" })} agentName="Mentor" />);
    openList();
    expect(await screen.findAllByRole('option')).toHaveLength(2);
    expect(screen.getByText("Couldn't refresh chats")).toBeInTheDocument();
  });

  test('create button disabled while creating', () => {
    render(<AgentChatSwitcher chatUi={ui({ creatingChat: true })} agentName="Mentor" />);
    expect(screen.getByRole('button', { name: 'New chat with Mentor' })).toBeDisabled();
  });
});
