import React from 'react';
import { mentionSegments } from '../lib/mentions.js';
import ProfileLink from './profile/ProfileLink.jsx';
import { INLINE_LINK_STYLE } from './profile/profileLinkStyles.js';

// Task 20261017-chat-mentions. Message body with mentions in bold (weight only,
// design-notes section 2). Plain text when there are no mentions or any range
// fails validation. No dangerouslySetInnerHTML: runs are React text nodes.
export default function MentionText({ text, mentions }) {
  if (!mentions || mentions.length === 0) return <>{text}</>;
  const segs = mentionSegments(text, mentions);
  if (segs.length === 1 && segs[0].type === 'text') return <>{text}</>;
  // Mention segments come out in the same order as `mentions` (validated ranges).
  let mi = 0;
  return (
    <>
      {segs.map((s, i) => (s.type === 'mention'
        ? (
          <strong key={i} className="msg-mention">
            <ProfileLink userId={mentions[mi++]?.userId} username={String(s.text).replace(/^@/, '')} style={INLINE_LINK_STYLE}>{s.text}</ProfileLink>
          </strong>
        )
        : <React.Fragment key={i}>{s.text}</React.Fragment>))}
    </>
  );
}
