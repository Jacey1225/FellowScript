import React from 'react';
import { mentionSegments } from '../lib/mentions.js';

// Task 20261017-chat-mentions. Message body with mentions in bold (weight only,
// design-notes section 2). Plain text when there are no mentions or any range
// fails validation. No dangerouslySetInnerHTML: runs are React text nodes.
export default function MentionText({ text, mentions }) {
  if (!mentions || mentions.length === 0) return <>{text}</>;
  const segs = mentionSegments(text, mentions);
  if (segs.length === 1 && segs[0].type === 'text') return <>{text}</>;
  return (
    <>
      {segs.map((s, i) => (s.type === 'mention'
        ? <strong key={i} className="msg-mention">{s.text}</strong>
        : <React.Fragment key={i}>{s.text}</React.Fragment>))}
    </>
  );
}
