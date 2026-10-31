import React from 'react';
import { Avatar, Typography } from 'antd';
import { UserOutlined, CheckCircleOutlined, ClockCircleOutlined, MailOutlined } from '@ant-design/icons';

const { Title } = Typography;

// Task 20261030-user-profiles: avatar, username and relationship chip
// (icon + text, never color alone). Never renders email, ids or timestamps.
const CHIPS = {
  friends: { icon: <CheckCircleOutlined />, text: 'Friends' },
  request_sent: { icon: <ClockCircleOutlined />, text: 'Request sent' },
  request_received: { icon: <MailOutlined />, text: 'Wants to be friends' },
};

export default function ProfileHeader({ profile }) {
  const state = profile.relationship?.state;
  const chip = CHIPS[state];
  return (
    <div style={{ textAlign: 'center' }}>
      <Avatar size={96} src={profile.profile_photo_url} icon={!profile.username ? <UserOutlined /> : undefined}
        style={{ background: 'rgba(212,146,42,0.18)', color: '#D4922A', fontSize: 38 }}>
        {(profile.username || '?')[0].toUpperCase()}
      </Avatar>
      <Title level={2} style={{ margin: '12px 0 4px', fontFamily: "'Playfair Display', serif", fontSize: 22, color: 'var(--parchment)', overflowWrap: 'anywhere' }}>
        {profile.username}
      </Title>
      {chip && (
        <div style={{ color: 'var(--ff-text-2)', fontSize: '0.85rem' }}>
          {chip.icon} <span style={{ marginLeft: 4 }}>{chip.text}</span>
        </div>
      )}
    </div>
  );
}
