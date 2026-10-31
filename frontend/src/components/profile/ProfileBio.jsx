import React from 'react';
import { Button } from 'antd';
import { EditOutlined } from '@ant-design/icons';

// Task 20261030-user-profiles: bio display by visibility tier. `bio` key is
// absent for strangers (hidden) and present (maybe null) for self/friends.
// Plain text only: React escapes it, no linkification.
const MUTED = { color: 'var(--ff-text-2)', margin: 0 };

export default function ProfileBio({ profile, onEdit }) {
  const state = profile.relationship?.state;
  const hasKey = Object.prototype.hasOwnProperty.call(profile, 'bio');
  if (!hasKey) return <p style={MUTED}>Bio is shared with friends.</p>;
  if (profile.bio) {
    return <p style={{ margin: 0, lineHeight: 1.45, fontSize: 16, color: 'var(--parchment)', overflowWrap: 'anywhere', whiteSpace: 'pre-wrap' }}>{profile.bio}</p>;
  }
  if (state === 'self' && profile.editable) {
    return (
      <div>
        <p style={MUTED}>Add a short bio so friends know who you are.</p>
        <Button type="default" icon={<EditOutlined />} onClick={onEdit} style={{ marginTop: 10, minHeight: 44 }}>Add bio</Button>
      </div>
    );
  }
  return <p style={MUTED}>No bio yet.</p>;
}
