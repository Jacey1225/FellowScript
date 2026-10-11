// Task 20261011-desktop-chat-replies-reactions: reply helpers.
import { describe, test, expect } from 'vitest';
import {
  replyFromWire, replyPreviewText, replyAuthorName, replyAuthorLabel, replySnippet,
  REPLY_UNAVAILABLE_LABEL, REPLY_SNIPPET_LIMIT,
} from './replies.js';

describe('replyFromWire', () => {
  test('full ref', () => {
    expect(replyFromWire({ reply_to_id: 'm1', reply_to_text: 'hi', reply_to_author: 'ada', reply_to_author_id: 'u2' }))
      .toEqual({ id: 'm1', text: 'hi', author: 'ada', authorId: 'u2', deleted: false });
  });
  test('absent or non-string id -> null', () => {
    expect(replyFromWire(null)).toBeNull();
    expect(replyFromWire({})).toBeNull();
    expect(replyFromWire({ reply_to_id: 5 })).toBeNull();
    expect(replyFromWire({ reply_to_id: '' })).toBeNull();
  });
  test('deleted original drops text/author even if the server sent them', () => {
    expect(replyFromWire({ reply_to_id: 'm1', reply_to_deleted: true, reply_to_text: 'secret', reply_to_author: 'ada' }))
      .toEqual({ id: 'm1', text: null, author: null, authorId: null, deleted: true });
  });
});

describe('labels', () => {
  test('preview text truncates and falls back by attachment kind', () => {
    expect(replyPreviewText({ text: 'x'.repeat(500) })).toHaveLength(REPLY_SNIPPET_LIMIT);
    expect(replyPreviewText({ text: ' ', attachmentKind: 'image' })).toBe('Photo');
    expect(replyPreviewText({ text: '', attachmentKind: 'video' })).toBe('Video');
    expect(replyPreviewText({ text: '', attachmentKind: 'gif' })).toBe('GIF');
    expect(replyPreviewText({ text: '', attachmentKind: 'file' })).toBe('File');
    expect(replyPreviewText({ text: '' })).toBe('Message');
  });
  test('author names', () => {
    expect(replyAuthorName({ mine: true })).toBe('You');
    expect(replyAuthorName({ sender: 'ada' })).toBe('ada');
    expect(replyAuthorName({})).toBe('Them');
    expect(replyAuthorLabel({ authorId: 'U1', author: 'me' }, 'u1')).toBe('You');
    expect(replyAuthorLabel({ authorId: 'u2', author: 'ada' }, 'u1')).toBe('ada');
    expect(replyAuthorLabel({ authorId: null, author: null }, 'u1')).toBe('Someone');
  });
  test('snippet: unavailable label when deleted; text otherwise; never empty', () => {
    expect(replySnippet({ deleted: true, text: 'x' })).toBe(REPLY_UNAVAILABLE_LABEL);
    expect(replySnippet({ deleted: false, text: ' hi ' })).toBe('hi');
    expect(replySnippet({ deleted: false, text: null })).toBe('Message');
  });
});
