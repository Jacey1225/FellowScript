import React from 'react';
import { Avatar } from 'antd';

// Task 20261030-profile-everywhere: DM thread header identity. Avatar and name
// are one button that opens the friend's profile (group headers keep opening
// group info and are handled separately in ChatThread).
export default function ChatHeaderIdentity({ contact, onViewProfile }) {
  return (
    <button
      type="button"
      className="group-info-header-btn"
      aria-label={`View ${contact.name}'s profile`}
      onClick={() => onViewProfile(contact.id)}
    >
      <Avatar size={32} src={contact.photoUrl} style={{ background: 'rgba(255,198,26,0.12)', color: 'var(--gold)', flexShrink: 0 }}>
        {(contact.name || '?')[0].toUpperCase()}
      </Avatar>
      <span className="group-info-header-name">{contact.name}</span>
    </button>
  );
}
