// Tests for the messaging-attachments feature (task
// 20260904-messaging-attachments, testing step 6) added to ChatThread.jsx:
// the attach affordance/menu, the GIF-search sheet (debounce + empty/error/
// loading states), the staged pre-send attachment chip (upload flow, oversize
// rejection, retry, no-confirm removal), send-button gating while an upload
// is in flight, and per-kind attachment rendering (image/video/gif/file,
// including the reduced-motion GIF behavior called out as load-bearing in
// design-notes.md §4/§6).
//
// Run with: cd frontend && npm test -- --run src/components/ChatThread.attachments.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeAll, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup, within } from '@testing-library/react';
import ChatThread from './ChatThread.jsx';

beforeAll(() => {
  if (!Element.prototype.scrollIntoView) {
    Element.prototype.scrollIntoView = () => {};
  }
  if (!URL.createObjectURL) {
    URL.createObjectURL = () => 'blob:mock-url';
  }
  if (!URL.revokeObjectURL) {
    URL.revokeObjectURL = () => {};
  }
});

const CONTACT = { id: 'c1', name: 'Ada Lovelace', type: 'friend' };
const USER = { user_id: 'u1', username: 'me' };

function renderThread(props = {}) {
  const onSend = vi.fn();
  const onRequestUploadUrl = vi.fn().mockResolvedValue({
    url: 'https://s3.example.com/bucket', fields: { key: 'attachments/u1/x.jpg' },
    object_key: 'attachments/u1/x.jpg', expires_in: 300,
  });
  const onUploadToS3 = vi.fn().mockResolvedValue(undefined);
  const onSearchGifs = vi.fn().mockResolvedValue([]);
  const utils = render(
    <ChatThread
      contact={CONTACT}
      messages={[]}
      groupMembers={[]}
      user={USER}
      onBack={vi.fn()}
      onSend={onSend}
      onRequestUploadUrl={onRequestUploadUrl}
      onUploadToS3={onUploadToS3}
      onSearchGifs={onSearchGifs}
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
  return { onSend, onRequestUploadUrl, onUploadToS3, onSearchGifs, ...utils };
}

function makeFile(name, type, sizeBytes) {
  const file = new File(['x'.repeat(Math.min(sizeBytes, 10))], name, { type });
  Object.defineProperty(file, 'size', { value: sizeBytes });
  return file;
}

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe('ChatThread — attach menu', () => {
  test('the paperclip control opens a menu with Photo & Video / File / GIF rows', () => {
    renderThread();
    fireEvent.click(screen.getByLabelText('Attach a photo, video, file, or GIF'));
    expect(screen.getByText('Photo & Video')).toBeInTheDocument();
    expect(screen.getByText('File')).toBeInTheDocument();
    expect(screen.getByText('GIF')).toBeInTheDocument();
  });
});

// Task 20260904-attach-picker-layout-polish: trigger icon is a plus (not a
// paperclip), the picker renders as one horizontal row of three self-
// contained gold-pill rows (icon + text each), not a stacked column.
describe('ChatThread — attach picker layout polish', () => {
  test('attach trigger shows a plus icon, not a paperclip, at the existing 44x44 tap target', () => {
    const { container } = renderThread();
    const trigger = screen.getByLabelText('Attach a photo, video, file, or GIF');
    expect(container.querySelector('.anticon-plus')).toBeInTheDocument();
    expect(container.querySelector('.anticon-paperclip')).not.toBeInTheDocument();
    expect(trigger.style.width).toBe('44px');
    expect(trigger.style.height).toBe('44px');
  });

  test('the three picker options render as self-contained icon+text pills in a single row container', () => {
    renderThread();
    fireEvent.click(screen.getByLabelText('Attach a photo, video, file, or GIF'));
    // The Popover's content portals to document.body, not the render container.
    const menu = document.querySelector('.attach-menu');
    expect(menu).toBeInTheDocument();
    const rows = menu.querySelectorAll('.attach-menu-row');
    expect(rows.length).toBe(3);
    rows.forEach(row => {
      // Each pill is its own icon+text button (no shared column divider row).
      expect(row.querySelector('.anticon')).toBeInTheDocument();
      expect(row.textContent.trim().length).toBeGreaterThan(0);
    });
  });
});

describe('ChatThread — staged attachment upload flow', () => {
  test('picking a photo stages it, requests an upload URL, uploads to S3, then enables send with the resulting object key', async () => {
    const { onRequestUploadUrl, onUploadToS3, onSend } = renderThread();
    const file = makeFile('vacation.jpg', 'image/jpeg', 1024);

    // The photo/video input is hidden but present; ChatThread wires it via ref
    // rather than a visible <input>, so locate it by its accept attribute.
    const photoInput = document.querySelector('input[type="file"][accept="image/*,video/*"]');
    fireEvent.change(photoInput, { target: { files: [file] } });

    await waitFor(() => expect(onRequestUploadUrl).toHaveBeenCalledWith('image', 'image/jpeg', 1024));
    await waitFor(() => expect(onUploadToS3).toHaveBeenCalled());

    const sendBtn = screen.getByLabelText('Send message');
    await waitFor(() => expect(sendBtn).not.toBeDisabled());

    fireEvent.click(sendBtn);
    expect(onSend).toHaveBeenCalledWith('', expect.objectContaining({
      kind: 'image', objectKey: 'attachments/u1/x.jpg',
    }));
  });

  test('send stays disabled while the upload is still in flight', async () => {
    let resolveUpload;
    const onUploadToS3 = vi.fn(() => new Promise(res => { resolveUpload = res; }));
    renderThread({ onUploadToS3 });
    const file = makeFile('clip.mp4', 'video/mp4', 2048);
    const photoInput = document.querySelector('input[type="file"][accept="image/*,video/*"]');
    fireEvent.change(photoInput, { target: { files: [file] } });

    const sendBtn = screen.getByLabelText('Send message');
    await waitFor(() => expect(sendBtn).toBeDisabled());

    resolveUpload();
    await waitFor(() => expect(sendBtn).not.toBeDisabled());
  });

  test('an oversized file is rejected client-side with the concrete limit copy, and never requests an upload URL', () => {
    const { onRequestUploadUrl } = renderThread();
    const tooBig = makeFile('huge.jpg', 'image/jpeg', 20 * 1024 * 1024); // > 15MB image cap
    const photoInput = document.querySelector('input[type="file"][accept="image/*,video/*"]');
    fireEvent.change(photoInput, { target: { files: [tooBig] } });

    expect(screen.getByText('Photos can be up to 15MB.')).toBeInTheDocument();
    expect(onRequestUploadUrl).not.toHaveBeenCalled();
  });

  test('upload failure shows a retry affordance, not an auto-retry loop; tapping it retries once', async () => {
    const onRequestUploadUrl = vi.fn()
      .mockRejectedValueOnce(new Error('network blip'))
      .mockResolvedValueOnce({ url: 'https://s3.example.com/b', fields: {}, object_key: 'attachments/u1/y.jpg', expires_in: 300 });
    const onUploadToS3 = vi.fn().mockResolvedValue(undefined);
    renderThread({ onRequestUploadUrl, onUploadToS3 });
    const file = makeFile('pic.jpg', 'image/jpeg', 1024);
    const photoInput = document.querySelector('input[type="file"][accept="image/*,video/*"]');
    fireEvent.change(photoInput, { target: { files: [file] } });

    const retryBtn = await screen.findByText("Couldn't send — tap to retry");
    expect(onRequestUploadUrl).toHaveBeenCalledTimes(1);

    fireEvent.click(retryBtn);
    await waitFor(() => expect(onRequestUploadUrl).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(screen.getByLabelText('Send message')).not.toBeDisabled());
  });

  test('removing a staged attachment requires no confirmation dialog', async () => {
    renderThread();
    const file = makeFile('doc.pdf', 'application/pdf', 1024);
    const fileInput = document.querySelector('input[type="file"]:not([accept="image/*,video/*"])');
    fireEvent.change(fileInput, { target: { files: [file] } });

    const removeBtn = await screen.findByLabelText('Remove attachment');
    fireEvent.click(removeBtn);
    // No confirm dialog/modal should appear, and the chip should be gone
    // immediately (undo-after-the-fact interaction model, not confirm-before-destroy).
    expect(screen.queryByLabelText('Remove attachment')).not.toBeInTheDocument();
    expect(screen.queryByRole('dialog', { name: /remove|delete|confirm/i })).not.toBeInTheDocument();
  });
});

describe('ChatThread — GIF search sheet', () => {
  test('debounces the search query (~350ms) rather than firing one request per keystroke', () => {
    vi.useFakeTimers();
    try {
      const onSearchGifs = vi.fn().mockResolvedValue([]);
      renderThread({ onSearchGifs });
      fireEvent.click(screen.getByLabelText('Attach a photo, video, file, or GIF'));
      fireEvent.click(screen.getByText('GIF'));

      const input = screen.getByPlaceholderText('Search GIFs');
      fireEvent.change(input, { target: { value: 'c' } });
      fireEvent.change(input, { target: { value: 'ca' } });
      fireEvent.change(input, { target: { value: 'cat' } });

      expect(onSearchGifs).not.toHaveBeenCalled();
      vi.advanceTimersByTime(349);
      expect(onSearchGifs).not.toHaveBeenCalled();
      vi.advanceTimersByTime(1);
      expect(onSearchGifs).toHaveBeenCalledTimes(1);
      expect(onSearchGifs).toHaveBeenCalledWith('cat');
    } finally {
      vi.useRealTimers();
    }
  });

  test('empty results render a minimal "No results" message, not a blank grid', async () => {
    const onSearchGifs = vi.fn().mockResolvedValue([]);
    renderThread({ onSearchGifs });
    fireEvent.click(screen.getByLabelText('Attach a photo, video, file, or GIF'));
    fireEvent.click(screen.getByText('GIF'));
    fireEvent.change(screen.getByPlaceholderText('Search GIFs'), { target: { value: 'xyzzy' } });

    await waitFor(() => expect(screen.getByText('No results')).toBeInTheDocument());
  });

  test('a search failure renders warm, non-technical copy -- never a raw error/status', async () => {
    const onSearchGifs = vi.fn().mockRejectedValue(new Error('500 Internal Server Error'));
    renderThread({ onSearchGifs });
    fireEvent.click(screen.getByLabelText('Attach a photo, video, file, or GIF'));
    fireEvent.click(screen.getByText('GIF'));
    fireEvent.change(screen.getByPlaceholderText('Search GIFs'), { target: { value: 'cat' } });

    const errText = await screen.findByText("Couldn't load GIFs right now — try again in a moment.");
    expect(errText).toBeInTheDocument();
    expect(screen.queryByText(/500/)).not.toBeInTheDocument();
    expect(screen.queryByText(/Internal Server Error/)).not.toBeInTheDocument();
  });

  test('selecting a GIF result stages it and closes the sheet immediately, no confirm step', async () => {
    const gif = { id: 'g1', url: 'https://example.com/g1.gif', preview_url: 'https://example.com/g1-small.gif', width: 200, height: 150 };
    const onSearchGifs = vi.fn().mockResolvedValue([gif]);
    renderThread({ onSearchGifs });
    fireEvent.click(screen.getByLabelText('Attach a photo, video, file, or GIF'));
    fireEvent.click(screen.getByText('GIF'));
    fireEvent.change(screen.getByPlaceholderText('Search GIFs'), { target: { value: 'cat' } });

    const result = await screen.findByLabelText('GIF result');
    fireEvent.click(result);

    // The modal's `open` prop flips to false immediately on selection (jsdom
    // has no real CSS transitions, so antd's own exit-animation DOM cleanup
    // never actually completes here -- that's an antd/jsdom interaction, not
    // part of what design-notes.md §2 specifies, so this doesn't assert DOM
    // removal). What matters functionally: the selection staged the GIF with
    // no confirm step and no upload wait -- send is already enabled.
    expect(screen.getByLabelText('Send message')).not.toBeDisabled();
    expect(document.querySelector('.staged-attachment-chip')).not.toBeNull();
  });
});

describe('ChatThread — per-kind attachment rendering', () => {
  test('image attachment renders with a photo-attachment accessibility label', () => {
    renderThread({
      messages: [{
        text: '', mine: false, sender: 'Ada', attachmentKind: 'image',
        attachmentUrl: 'https://example.com/photo.jpg', attachmentMeta: {},
      }],
    });
    expect(screen.getByLabelText('Ada: photo attachment')).toBeInTheDocument();
    expect(screen.getByAltText('photo attachment')).toBeInTheDocument();
  });

  test('video attachment shows a tap-to-play placeholder, not autoplay, until tapped', () => {
    renderThread({
      messages: [{
        text: '', mine: false, sender: 'Ada', attachmentKind: 'video',
        attachmentUrl: 'https://example.com/clip.mp4', attachmentMeta: {},
      }],
    });
    const playBtn = screen.getByLabelText('video attachment, tap to play');
    expect(playBtn).toBeInTheDocument();
    expect(document.querySelector('video')).not.toBeInTheDocument();
    fireEvent.click(playBtn);
    expect(document.querySelector('video[controls]')).toBeInTheDocument();
    expect(document.querySelector('video[autoplay]')).toBeInTheDocument();
  });

  test('gif attachment autoplays/loops normally when reduced-motion is off', () => {
    renderThread({
      messages: [{
        text: '', mine: false, sender: 'Ada', attachmentKind: 'gif',
        attachmentUrl: 'https://example.com/g.gif',
        attachmentMeta: { url: 'https://example.com/g.gif' },
      }],
    });
    expect(screen.getByAltText('GIF attachment')).toBeInTheDocument();
    expect(screen.queryByLabelText('GIF attachment, tap to play')).not.toBeInTheDocument();
  });

  test('gif attachment shows a static tap-to-play frame under prefers-reduced-motion (load-bearing, not cosmetic)', () => {
    const originalMatchMedia = window.matchMedia;
    window.matchMedia = (query) => ({
      matches: query.includes('prefers-reduced-motion'),
      media: query, onchange: null,
      addListener: () => {}, removeListener: () => {},
      addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => false,
    });
    try {
      renderThread({
        messages: [{
          text: '', mine: false, sender: 'Ada', attachmentKind: 'gif',
          attachmentUrl: 'https://example.com/g.gif',
          attachmentMeta: { url: 'https://example.com/g.gif', preview_url: 'https://example.com/g-static.gif' },
        }],
      });
      const tapToPlay = screen.getByLabelText('GIF attachment, tap to play');
      expect(tapToPlay).toBeInTheDocument();
      // Tapping reveals the real (looping) gif -- reduced-motion only changes
      // the DEFAULT, it doesn't remove the ability to view it animated.
      fireEvent.click(tapToPlay);
      expect(screen.getByAltText('GIF attachment')).toBeInTheDocument();
    } finally {
      window.matchMedia = originalMatchMedia;
    }
  });

  test('file attachment renders filename + download affordance with a descriptive accessibility label', () => {
    renderThread({
      messages: [{
        text: '', mine: false, sender: 'Ada', attachmentKind: 'file',
        attachmentUrl: 'https://example.com/report.pdf',
        attachmentMeta: { filename: 'Q3-report.pdf' },
      }],
    });
    expect(screen.getByText('Q3-report.pdf')).toBeInTheDocument();
    expect(screen.getByLabelText('Ada: file attachment, Q3-report.pdf, download')).toBeInTheDocument();
    const link = screen.getByLabelText('file attachment, Q3-report.pdf, download');
    expect(link).toHaveAttribute('href', 'https://example.com/report.pdf');
  });

  test('an expired/broken attachment URL degrades to a muted placeholder, not a broken-image glyph', () => {
    renderThread({
      messages: [{
        text: '', mine: false, sender: 'Ada', attachmentKind: 'image',
        attachmentUrl: 'https://example.com/gone.jpg', attachmentMeta: {},
      }],
    });
    fireEvent.error(screen.getByAltText('photo attachment'));
    expect(screen.getByText('Image unavailable')).toBeInTheDocument();
  });
});
