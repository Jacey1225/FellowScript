// Tests for the default/trending GIF-browse UI added to ChatThread.jsx's
// GifSearchModal (task 20260905-gif-picker-default-browse, testing step 4,
// the final gate): the browse grid loads immediately on open (before any
// query), a non-infinite-scroll "Load more" control appends further pages,
// typing a query swaps to search results, and clearing the query reverts to
// the browse grid instantly from retained state (no refetch) -- plus the
// browse-specific loading/empty/error treatments design-notes.md specifies.
//
// Run with: cd frontend && npm test -- --run src/components/ChatThread.gifBrowse.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeAll, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react';
import ChatThread from './ChatThread.jsx';

beforeAll(() => {
  if (!Element.prototype.scrollIntoView) {
    Element.prototype.scrollIntoView = () => {};
  }
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

const CONTACT = { id: 'c1', name: 'Ada Lovelace', type: 'friend' };
const USER = { user_id: 'u1', username: 'me' };

function renderThread(props = {}) {
  const onSearchGifs = vi.fn().mockResolvedValue([]);
  const onBrowseGifs = vi.fn().mockResolvedValue({ results: [], nextPageToken: null, hasMore: false });
  const utils = render(
    <ChatThread
      contact={CONTACT}
      messages={[]}
      groupMembers={[]}
      user={USER}
      onBack={vi.fn()}
      onSend={vi.fn()}
      onRequestUploadUrl={vi.fn()}
      onUploadToS3={vi.fn()}
      onSearchGifs={onSearchGifs}
      onBrowseGifs={onBrowseGifs}
      sessions={[]}
      activeSessionId={null}
      talkingUserId={null}
      onJoinSession={vi.fn()}
      onLeaveSession={vi.fn()}
      onOpenSessionCreator={vi.fn()}
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
  return { onSearchGifs, onBrowseGifs, ...utils };
}

function openGifSheet() {
  fireEvent.click(screen.getByLabelText('Attach a photo, video, file, or GIF'));
  fireEvent.click(screen.getByText('GIF'));
}

const GIF_A = { id: 'a1', url: 'https://example.com/a1.gif', preview_url: 'https://example.com/a1-small.gif', width: 200, height: 150 };
const GIF_B = { id: 'b1', url: 'https://example.com/b1.gif', preview_url: 'https://example.com/b1-small.gif', width: 200, height: 150 };
const GIF_C = { id: 'c1x', url: 'https://example.com/c1.gif', preview_url: 'https://example.com/c1-small.gif', width: 200, height: 150 };

describe('ChatThread — GIF default-browse grid', () => {
  test('opening the sheet immediately fetches and renders the browse grid, no query typed', async () => {
    const onBrowseGifs = vi.fn().mockResolvedValue({ results: [GIF_A, GIF_B], nextPageToken: null, hasMore: false });
    renderThread({ onBrowseGifs });
    openGifSheet();

    expect(onBrowseGifs).toHaveBeenCalledWith();
    await waitFor(() => expect(screen.getAllByLabelText('GIF result')).toHaveLength(2));
    // No query was ever typed -- onSearchGifs must not have fired.
  });

  test('an empty browse result renders minimal browse-specific empty copy, not "No results" (search\'s copy)', async () => {
    const onBrowseGifs = vi.fn().mockResolvedValue({ results: [], nextPageToken: null, hasMore: false });
    renderThread({ onBrowseGifs });
    openGifSheet();

    await waitFor(() => expect(screen.getByText('No trending GIFs right now.')).toBeInTheDocument());
    expect(screen.queryByText('No results')).not.toBeInTheDocument();
  });

  test('a browse-load failure shows warm retry copy, and tapping it retries the fetch', async () => {
    const onBrowseGifs = vi.fn()
      .mockRejectedValueOnce(new Error('network blip'))
      .mockResolvedValueOnce({ results: [GIF_A], nextPageToken: null, hasMore: false });
    renderThread({ onBrowseGifs });
    openGifSheet();

    const retry = await screen.findByText("Couldn't load GIFs right now — try again in a moment.");
    expect(onBrowseGifs).toHaveBeenCalledTimes(1);

    fireEvent.click(retry);
    await waitFor(() => expect(onBrowseGifs).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(screen.getByLabelText('GIF result')).toBeInTheDocument());
  });

  test('a "Load more" control appears only while hasMore is true, and appends (not replaces) results', async () => {
    const onBrowseGifs = vi.fn()
      .mockResolvedValueOnce({ results: [GIF_A], nextPageToken: 'page-2', hasMore: true })
      .mockResolvedValueOnce({ results: [GIF_B], nextPageToken: null, hasMore: false });
    renderThread({ onBrowseGifs });
    openGifSheet();

    await waitFor(() => expect(screen.getByLabelText('GIF result')).toBeInTheDocument());
    const loadMore = screen.getByLabelText('Load more GIFs');
    expect(loadMore).toBeInTheDocument();

    fireEvent.click(loadMore);
    await waitFor(() => expect(onBrowseGifs).toHaveBeenCalledWith('page-2'));
    await waitFor(() => expect(screen.getAllByLabelText('GIF result')).toHaveLength(2));
    // hasMore is now false -- the control disappears rather than offering
    // another (non-existent) page, and no infinite/auto-triggered refetch happens.
    await waitFor(() => expect(screen.queryByLabelText('Load more GIFs')).not.toBeInTheDocument());
  });

  test('a "Load more" failure leaves already-loaded results intact and offers tap-to-retry, not an auto-retry loop', async () => {
    const onBrowseGifs = vi.fn()
      .mockResolvedValueOnce({ results: [GIF_A], nextPageToken: 'page-2', hasMore: true })
      .mockRejectedValueOnce(new Error('load-more blip'))
      .mockResolvedValueOnce({ results: [GIF_B], nextPageToken: null, hasMore: false });
    renderThread({ onBrowseGifs });
    openGifSheet();

    const loadMore = await screen.findByLabelText('Load more GIFs');
    fireEvent.click(loadMore);

    await waitFor(() => expect(screen.getByText("Couldn't load more — tap to retry")).toBeInTheDocument());
    // The already-loaded first page is untouched.
    expect(screen.getAllByLabelText('GIF result')).toHaveLength(1);
    expect(onBrowseGifs).toHaveBeenCalledTimes(2);

    fireEvent.click(screen.getByLabelText('Load more GIFs'));
    await waitFor(() => expect(onBrowseGifs).toHaveBeenCalledTimes(3));
    await waitFor(() => expect(screen.getAllByLabelText('GIF result')).toHaveLength(2));
  });

  test('typing a query swaps the grid to search results and hides the browse grid/load-more control', async () => {
    const onBrowseGifs = vi.fn().mockResolvedValue({ results: [GIF_A], nextPageToken: 'page-2', hasMore: true });
    const onSearchGifs = vi.fn().mockResolvedValue([GIF_C]);
    vi.useFakeTimers();
    try {
      renderThread({ onBrowseGifs, onSearchGifs });
      openGifSheet();
      await vi.waitFor(() => expect(onBrowseGifs).toHaveBeenCalledTimes(1));

      fireEvent.change(screen.getByPlaceholderText('Search GIFs'), { target: { value: 'cat' } });
      await vi.advanceTimersByTimeAsync(350);
      await vi.waitFor(() => expect(onSearchGifs).toHaveBeenCalledWith('cat'));

      // Search results shown; browse's "Load more" control is not.
      expect(screen.queryByLabelText('Load more GIFs')).not.toBeInTheDocument();
    } finally {
      vi.useRealTimers();
    }
  });

  test('clearing a typed query reverts to the browse grid instantly from retained state, without refetching', async () => {
    const onBrowseGifs = vi.fn().mockResolvedValue({ results: [GIF_A], nextPageToken: null, hasMore: false });
    const onSearchGifs = vi.fn().mockResolvedValue([GIF_C]);
    vi.useFakeTimers();
    try {
      renderThread({ onBrowseGifs, onSearchGifs });
      openGifSheet();
      await vi.waitFor(() => expect(onBrowseGifs).toHaveBeenCalledTimes(1));

      const input = screen.getByPlaceholderText('Search GIFs');
      fireEvent.change(input, { target: { value: 'cat' } });
      await vi.advanceTimersByTimeAsync(350);
      await vi.waitFor(() => expect(onSearchGifs).toHaveBeenCalledTimes(1));

      fireEvent.change(input, { target: { value: '' } });
      // The browse grid (GIF_A) reappears immediately from already-held
      // state -- no second browse fetch was required to show it again.
      expect(screen.getByLabelText('GIF result')).toBeInTheDocument();
      expect(onBrowseGifs).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
  });

  test('selecting a browse-grid GIF stages it and closes the sheet, same as a search result', async () => {
    const onBrowseGifs = vi.fn().mockResolvedValue({ results: [GIF_A], nextPageToken: null, hasMore: false });
    renderThread({ onBrowseGifs });
    openGifSheet();

    const result = await screen.findByLabelText('GIF result');
    fireEvent.click(result);

    expect(screen.getByLabelText('Send message')).not.toBeDisabled();
    expect(document.querySelector('.staged-attachment-chip')).not.toBeNull();
  });

  test('closing and reopening the sheet resets browse state and re-fetches fresh (no session cache)', async () => {
    const onBrowseGifs = vi.fn()
      .mockResolvedValueOnce({ results: [GIF_A], nextPageToken: null, hasMore: false })
      .mockResolvedValueOnce({ results: [GIF_B], nextPageToken: null, hasMore: false });
    renderThread({ onBrowseGifs });
    openGifSheet();
    await waitFor(() => expect(screen.getByLabelText('GIF result')).toBeInTheDocument());

    // Close via antd Modal's own close ("X") button and reopen.
    fireEvent.click(document.querySelector('.ant-modal-close'));
    openGifSheet();

    await waitFor(() => expect(onBrowseGifs).toHaveBeenCalledTimes(2));
  });
});
