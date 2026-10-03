// Task 20261003-web-reader-ios-parity step 4: Explore groups row, failed-send
// bubble render. Run: npx vitest run src/components/ExploreAndRetry.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import { CapabilitiesContext } from '../context/CapabilitiesContext.jsx';
import { exploreEntryUrl } from '../lib/exploreEntry.js';
import ContactsPanel from './ContactsPanel.jsx';

vi.mock('./GroupInfoPanel.jsx', () => ({ default: () => null }));
import ChatThread from './ChatThread.jsx';

afterEach(() => { cleanup(); vi.restoreAllMocks(); });
beforeEach(() => {
  Element.prototype.scrollIntoView = vi.fn();
  window.matchMedia = vi.fn(() => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }));
});

describe('exploreEntryUrl', () => {
  const on = { features: { explorer_browse: true }, links: { explore: 'https://fellowscript.com/#/explore' } };
  test('returns the https link only when explorer_browse is on', () => {
    expect(exploreEntryUrl(on)).toBe('https://fellowscript.com/#/explore');
    expect(exploreEntryUrl({ ...on, features: { explorer_browse: false } })).toBeNull();
    expect(exploreEntryUrl({ features: {}, links: { explore: null } })).toBeNull();
  });
  test('fails closed on non-https, malformed or missing links', () => {
    expect(exploreEntryUrl({ ...on, links: { explore: 'http://x.test/' } })).toBeNull();
    expect(exploreEntryUrl({ ...on, links: { explore: 'javascript:alert(1)' } })).toBeNull();
    expect(exploreEntryUrl({ ...on, links: { explore: 'nope' } })).toBeNull();
    expect(exploreEntryUrl({ ...on, links: {} })).toBeNull();
    expect(exploreEntryUrl(null)).toBeNull();
  });
});

function contacts(caps) {
  return render(
    <CapabilitiesContext.Provider value={{ ...caps, isEnabled: () => false, refresh: vi.fn() }}>
      <ContactsPanel user={{ user_id: 'u1' }} friends={[]} groups={{}} currentContact={null}
        onOpen={vi.fn()} onAddFriend={vi.fn()} onRemoveFriend={vi.fn()} onCreateGroup={vi.fn()}
        onUpdateGroup={vi.fn()} onLeaveGroup={vi.fn()} loaded onLoad={vi.fn()} showAgents={false} />
    </CapabilitiesContext.Provider>,
  );
}

describe('Explore groups row in the Reader groups list', () => {
  test('shown when explorer_browse is on and opens the https link externally', () => {
    const open = vi.spyOn(window, 'open').mockImplementation(() => null);
    contacts({ features: { explorer_browse: true }, links: { explore: 'https://fellowscript.com/#/explore' } });
    fireEvent.click(screen.getByRole('button', { name: /Explore groups/ }));
    expect(open).toHaveBeenCalledWith('https://fellowscript.com/#/explore', '_blank', 'noopener,noreferrer');
  });
  test('hidden when the flag is off', () => {
    contacts({ features: {}, links: { explore: null } });
    expect(screen.queryByRole('button', { name: /Explore groups/ })).toBeNull();
  });
  test('icon-only add buttons have accessible names', () => {
    contacts({ features: {}, links: { explore: null } });
    expect(screen.getByRole('button', { name: 'Add a friend' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Create a group' })).toBeInTheDocument();
  });
});

describe('failed message bubble', () => {
  function chat(messages, onRetryMessage = vi.fn()) {
    render(
      <ChatThread contact={{ id: 'f1', name: 'Ada', type: 'friend', toUsers: ['f1'] }} messages={messages} groupMembers={[]}
        user={{ user_id: 'u1' }} sessions={[]} activeSessionId={null} onBack={vi.fn()} onSend={vi.fn()}
        onRetryMessage={onRetryMessage} onJoinSession={vi.fn()} onLeaveSession={vi.fn()} onOpenSessionCreator={vi.fn()}
        onEditSession={vi.fn()} onDeleteSession={vi.fn()} onNavigateVerse={vi.fn()} onToggleVideo={vi.fn()} bindVideoTile={vi.fn()} />,
    );
    return onRetryMessage;
  }
  test('failed bubble shows a retry control that calls back with the message', () => {
    const m = { text: 'hi', mine: true, failed: true, timestamp: '2026-10-03T10:00:00Z' };
    const retry = chat([m]);
    fireEvent.click(screen.getByRole('button', { name: 'Message not sent. Tap to retry' }));
    expect(retry).toHaveBeenCalledWith(m);
  });
  test('a normal bubble has no retry control', () => {
    chat([{ text: 'hi', mine: true, timestamp: '2026-10-03T10:00:00Z' }]);
    expect(screen.queryByRole('button', { name: /Tap to retry/ })).toBeNull();
  });
});
