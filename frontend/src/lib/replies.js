// Task 20261011-desktop-chat-replies-reactions. Reply (quote) helpers, mirroring
// FSReplyRef / FSMessage reply helpers in Models.swift. Server-supplied text is
// only ever rendered as plain text by the callers.

export const REPLY_UNAVAILABLE_LABEL = 'Original message unavailable';
export const REPLY_SNIPPET_LIMIT = 200;

// Build a reply ref from wire keys (history row, live frame or ack) or null.
export function replyFromWire(src) {
  if (!src || typeof src !== 'object') return null;
  const id = src.reply_to_id;
  if (typeof id !== 'string' || !id) return null;
  const deleted = src.reply_to_deleted === true;
  const str = (v) => (!deleted && typeof v === 'string' ? v : null);
  return { id, text: str(src.reply_to_text), author: str(src.reply_to_author), authorId: str(src.reply_to_author_id), deleted };
}

// Short text for the composer bar and optimistic quote: text, else attachment kind.
export function replyPreviewText(m) {
  const t = (m.text || '').trim();
  if (t) return t.slice(0, REPLY_SNIPPET_LIMIT);
  switch (m.attachmentKind) {
    case 'image': return 'Photo';
    case 'video': return 'Video';
    case 'gif': return 'GIF';
    case 'file': return 'File';
    default: return 'Message';
  }
}

export function replyAuthorName(m) {
  return m.mine ? 'You' : (m.sender ? m.sender : 'Them');
}

// "You" when the quoted message is the viewer's own.
export function replyAuthorLabel(reply, viewerId) {
  if (viewerId && reply.authorId && reply.authorId.toLowerCase() === String(viewerId).toLowerCase()) return 'You';
  return reply.author ? reply.author : 'Someone';
}

export function replySnippet(reply) {
  if (reply.deleted) return REPLY_UNAVAILABLE_LABEL;
  const t = (reply.text || '').trim();
  return t || 'Message';
}
