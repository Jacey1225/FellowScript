import React from 'react';
import { Link } from 'react-router-dom';
import { Card, Typography } from 'antd';
import { UserOutlined, RightOutlined } from '@ant-design/icons';
import { FORM_CARD_STYLE } from '../forms/index.js';

const { Text } = Typography;

// Task 20261030-user-profiles: the single Account entry to the profile page
// (bio editing lives on /profile/:id, not on Account).
export default function ViewMyProfileRow({ userId }) {
  if (!userId) return null;
  return (
    <Card style={FORM_CARD_STYLE}>
      <Link to={`/profile/${encodeURIComponent(userId)}`} aria-label="View my profile"
        style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: '1rem', textDecoration: 'none', minHeight: 44 }}>
        <span style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
          <Text className="fs-eyebrow" style={{ marginBottom: 0 }}><UserOutlined aria-hidden="true" style={{ marginRight: 8 }} />View my profile</Text>
          <Text style={{ fontFamily: 'inherit', fontSize: '0.82rem', color: 'rgba(244,228,193,0.6)' }}>See your profile and edit your bio.</Text>
        </span>
        <RightOutlined aria-hidden="true" style={{ color: 'rgba(200,134,26,0.7)' }} />
      </Link>
    </Card>
  );
}
