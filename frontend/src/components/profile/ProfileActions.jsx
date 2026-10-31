import React from 'react';
import { Button, Dropdown } from 'antd';
import { UserAddOutlined, MessageOutlined, CheckOutlined, EditOutlined, MoreOutlined, FlagOutlined, StopOutlined, DeleteOutlined } from '@ant-design/icons';

// Task 20261030-user-profiles: primary/secondary action by relationship
// state, plus the overflow menu. `busy` is the key of the in-flight action;
// only that button spins, and double taps are ignored while busy.
const BTN = { minHeight: 44, flex: 1 };

export function ProfileOverflow({ profile, onReport, onBlock, onUnfriend }) {
  const state = profile.relationship?.state;
  if (state === 'self') return null;
  const items = [
    ...(state === 'friends' ? [{ key: 'unfriend', icon: <DeleteOutlined />, label: 'Unfriend', danger: true }] : []),
    { key: 'block', icon: <StopOutlined />, label: 'Block', danger: true },
    { key: 'report', icon: <FlagOutlined />, label: 'Report' },
  ];
  const onClick = ({ key }) => ({ unfriend: onUnfriend, block: onBlock, report: onReport })[key]?.();
  return (
    <Dropdown menu={{ items, onClick }} trigger={['click']} placement="bottomRight">
      <Button type="text" aria-label={`More options for ${profile.username}`} style={{ minWidth: 44, minHeight: 44, padding: 0, display: 'inline-flex', alignItems: 'center', justifyContent: 'center' }}>
        <span aria-hidden="true" style={{ width: 36, height: 36, borderRadius: '50%', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', background: 'var(--ff-card)', border: '1px solid var(--ff-card-border)', color: 'rgba(200,134,26,0.9)' }}>
          <MoreOutlined />
        </span>
      </Button>
    </Dropdown>
  );
}

export default function ProfileActions({ profile, busy, onAdd, onAccept, onDecline, onMessage, onEdit, editing }) {
  const state = profile.relationship?.state;
  const name = profile.username;
  const run = (key, fn) => () => { if (!busy) fn(); };
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, alignItems: 'center' }}>
      {state === 'none' && (
        <Button type="primary" icon={<UserAddOutlined />} style={BTN} loading={busy === 'add'} aria-busy={busy === 'add'}
          aria-label={`Add ${name} as a friend`} onClick={run('add', onAdd)}>Add friend</Button>
      )}
      {state === 'request_sent' && <Button disabled style={BTN}>Request sent</Button>}
      {state === 'request_received' && (
        <>
          <Button type="primary" icon={<CheckOutlined />} style={BTN} loading={busy === 'accept'} aria-busy={busy === 'accept'}
            aria-label={`Accept friend request from ${name}`} onClick={run('accept', onAccept)}>Accept</Button>
          {onDecline && <Button type="text" style={{ minHeight: 44 }} loading={busy === 'decline'} aria-label={`Decline friend request from ${name}`} onClick={run('decline', onDecline)}>Decline</Button>}
        </>
      )}
      {state === 'friends' && (
        <Button type="primary" icon={<MessageOutlined />} style={BTN} aria-label={`Message ${name}`} onClick={onMessage}>Message</Button>
      )}
      {state === 'self' && profile.editable && !editing && (
        <Button icon={<EditOutlined />} style={BTN} onClick={onEdit}>Edit bio</Button>
      )}
    </div>
  );
}
