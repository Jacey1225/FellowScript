// The NoteDetail reply box must keep the draft when a reply is rejected
// (task 20260929-free-note-char-cap) and clear it on success.
//
// Run with: cd frontend && npm test -- --run src/components/panels/notes/NoteDetail.replyDraft.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react';

afterEach(() => cleanup());
import NoteDetail from './NoteDetail.jsx';

function renderDetail(onReply) {
  return render(
    <NoteDetail
      note={{ title: 'N', text: '<p>body</p>', verses: [] }}
      noteId="n1" onBack={() => {}} canReply onReply={onReply}
      replies={[]} repliesLoading={false} onNavigateVerse={() => {}}
    />
  );
}

async function typeAndSend(text) {
  const box = screen.getByPlaceholderText('Write a reply…');
  fireEvent.change(box, { target: { value: text } });
  fireEvent.click(screen.getByRole('button', { name: /reply/i }));
  return box;
}

describe('NoteDetail reply box', () => {
  test('rejected reply (onReply resolves false) keeps the draft', async () => {
    const onReply = vi.fn(async () => false);
    renderDetail(onReply);
    const box = await typeAndSend('a long reply the server refused');
    await waitFor(() => expect(onReply).toHaveBeenCalledWith('n1', 'a long reply the server refused'));
    await waitFor(() => expect(screen.getByRole('button', { name: /reply/i })).not.toHaveClass('ant-btn-loading'));
    expect(box.value).toBe('a long reply the server refused');
  });

  test('successful reply (true) clears the draft', async () => {
    const onReply = vi.fn(async () => true);
    renderDetail(onReply);
    const box = await typeAndSend('ok reply');
    await waitFor(() => expect(box.value).toBe(''));
  });

  test('legacy handlers returning undefined still clear the draft', async () => {
    const onReply = vi.fn(async () => {});
    renderDetail(onReply);
    const box = await typeAndSend('ok reply');
    await waitFor(() => expect(box.value).toBe(''));
  });

  test('blank reply is never sent', async () => {
    const onReply = vi.fn(async () => true);
    renderDetail(onReply);
    await typeAndSend('   ');
    expect(onReply).not.toHaveBeenCalled();
  });
});
