import React from 'react';
import { Avatar } from 'antd';

// Task 20261017-chat-mentions. Presentational @ picker (design-notes sections 1
// and 3). Focus never leaves the composer: the input owns the combobox
// semantics (aria-activedescendant) and this list only renders options. Rows
// use onMouseDown preventDefault so a click keeps focus in the input.
export const MENTION_LISTBOX_ID = 'mention-picker-listbox';
export const mentionOptionId = (userId) => `mention-option-${userId}`;

export default function MentionPicker({ members, activeIndex, onPick, photoFor }) {
  return (
    <div className="mention-picker-anchor">
      <div className="mention-picker">
        <div id={MENTION_LISTBOX_ID} role="listbox" aria-label="Mention a member" className="mention-picker-list">
          {members.length === 0 && <div className="mention-picker-empty" role="presentation">No one matches</div>}
          {members.map((m, i) => (
            // eslint-disable-next-line jsx-a11y/click-events-have-key-events
            <div
              key={m.user_id}
              id={mentionOptionId(m.user_id)}
              role="option"
              aria-selected={i === activeIndex}
              className={`mention-picker-row${i === activeIndex ? ' mention-picker-row-active' : ''}`}
              onMouseDown={(e) => { e.preventDefault(); onPick(m); }}
            >
              <Avatar size={32} src={photoFor ? photoFor(m) : undefined} aria-hidden="true"
                style={{ background: 'rgba(255,198,26,0.12)', color: 'var(--gold)', flexShrink: 0 }}>
                {(m.username || '?')[0].toUpperCase()}
              </Avatar>
              <span className="mention-picker-name">{m.username}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
