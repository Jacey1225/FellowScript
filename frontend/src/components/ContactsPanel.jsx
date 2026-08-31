import React, { useState, useEffect } from 'react';
import { Button, Avatar, Typography, Modal, Form, Checkbox, Spin, Dropdown, Radio, Input, message as antMessage } from 'antd';
import {
  MessageOutlined, PlusOutlined, EditOutlined, DeleteOutlined, UserAddOutlined,
  RobotOutlined, MoreOutlined, FlagOutlined, StopOutlined,
} from '@ant-design/icons';

const { Text } = Typography;

function agentLabel(agent) {
  if (agent?.name) return agent.name;
  if (!agent?.role || agent.role.startsWith('You are a spiritual')) return 'Spiritual Guide';
  const firstLine = agent.role.split('\n').find(l => l.trim());
  return (firstLine || '').slice(0, 26) || 'Agent';
}

// ── Agent row ─────────────────────────────────────────────────────────────────

function AgentRow({ agent, active, onOpen }) {
  return (
    <div
      onClick={onOpen}
      style={{
        display: 'flex', alignItems: 'center', gap: '0.5rem',
        padding: '0.55rem 0.8rem', cursor: 'pointer',
        background: active ? 'rgba(255,198,26,0.12)' : 'transparent',
        borderLeft: `2px solid ${active ? 'var(--gold)' : 'transparent'}`,
        transition: 'background 0.15s, border-color 0.15s',
      }}
      onMouseEnter={e => { if (!active) e.currentTarget.style.background = 'rgba(255,198,26,0.06)'; }}
      onMouseLeave={e => { if (!active) e.currentTarget.style.background = 'transparent'; }}
    >
      <div style={{
        width: 30, height: 30, borderRadius: '50%', flexShrink: 0,
        background: 'rgba(255,198,26,0.12)', border: 'none',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>
        <RobotOutlined style={{ color: 'var(--gold)', fontSize: '0.8rem' }} />
      </div>
      <Text style={{
        fontFamily: "'Inter', sans-serif", fontSize: '0.72rem',
        color: active ? 'var(--parchment)' : 'rgba(242,242,242,0.65)',
        overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1,
      }}>
        {agentLabel(agent)}
      </Text>
    </div>
  );
}

// ── Contact row ───────────────────────────────────────────────────────────────

function ContactRow({ contact, active, onOpen, onRemove, onEdit, onReport, onBlock }) {
  const isFriend = contact.type === 'friend';
  const menuItems = isFriend ? [
    { key: 'report', icon: <FlagOutlined />, label: 'Report User' },
    { key: 'block', icon: <StopOutlined />, label: 'Block User', danger: true },
    { key: 'remove', icon: <DeleteOutlined />, label: 'Remove Friend', danger: true },
  ] : [
    { key: 'edit', icon: <EditOutlined />, label: 'Edit Group' },
    { key: 'remove', icon: <DeleteOutlined />, label: 'Leave Group', danger: true },
  ];
  const handleMenuClick = ({ key, domEvent }) => {
    domEvent.stopPropagation();
    if (key === 'report') onReport(contact);
    else if (key === 'block') onBlock(contact);
    else if (key === 'remove') onRemove();
    else if (key === 'edit') onEdit();
  };
  return (
    <div
      onClick={() => onOpen(contact)}
      style={{
        display: 'flex', alignItems: 'center', gap: '0.5rem',
        padding: '0.55rem 0.8rem', cursor: 'pointer',
        background: active ? 'rgba(255,198,26,0.12)' : 'transparent',
        borderLeft: `2px solid ${active ? 'var(--gold)' : 'transparent'}`,
        transition: 'background 0.15s, border-color 0.15s',
      }}
      onMouseEnter={e => { if (!active) e.currentTarget.style.background = 'rgba(255,198,26,0.06)'; }}
      onMouseLeave={e => { if (!active) e.currentTarget.style.background = 'transparent'; }}
    >
      <Avatar
        size={30}
        style={{ background: 'rgba(255,198,26,0.15)', border: 'none', color: 'var(--gold)', fontSize: '0.72rem', flexShrink: 0, fontFamily: "'Space Grotesk', sans-serif" }}
      >
        {contact.name[0].toUpperCase()}
      </Avatar>
      <Text
        style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.72rem', color: active ? 'var(--parchment)' : 'rgba(242,242,242,0.65)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}
      >
        {contact.name}
      </Text>
      <Dropdown menu={{ items: menuItems, onClick: handleMenuClick }} trigger={['click']} placement="bottomRight">
        <Button
          type="text" size="small" icon={<MoreOutlined />}
          onClick={e => e.stopPropagation()}
          style={{ color: 'rgba(255,198,26,0.4)', padding: '0 4px', flexShrink: 0 }}
        />
      </Dropdown>
    </div>
  );
}

// ── Report user modal ─────────────────────────────────────────────────────────

const REPORT_REASONS = [
  { value: 'harassment', label: 'Harassment or abusive behavior' },
  { value: 'hate_speech', label: 'Hate speech or discrimination' },
  { value: 'sexual_content', label: 'Sexually explicit or inappropriate content' },
  { value: 'spam', label: 'Spam or scam' },
  { value: 'other', label: 'Other' },
];

function ReportUserModal({ target, onSubmit, onClose }) {
  const [reason, setReason] = useState('harassment');
  const [detail, setDetail] = useState('');
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => { if (target) { setReason('harassment'); setDetail(''); } }, [target]);

  const handleOk = async () => {
    setSubmitting(true);
    const ok = await onSubmit(target.id, reason, detail);
    setSubmitting(false);
    antMessage[ok ? 'success' : 'error'](ok ? 'Report submitted. We review every report within 24 hours.' : 'Could not submit report.');
    onClose();
  };

  return (
    <Modal
      open={!!target}
      title={<Text style={{ fontFamily: "'Space Grotesk', sans-serif", color: 'var(--parchment)' }}>Report {target?.name}</Text>}
      onOk={handleOk}
      onCancel={onClose}
      confirmLoading={submitting}
      okText="Submit Report"
      okButtonProps={{ danger: true }}
    >
      <Radio.Group value={reason} onChange={e => setReason(e.target.value)} style={{ display: 'flex', flexDirection: 'column', gap: 8, marginBottom: 12 }}>
        {REPORT_REASONS.map(r => (
          <Radio key={r.value} value={r.value} style={{ color: 'rgba(242,242,242,0.75)' }}>{r.label}</Radio>
        ))}
      </Radio.Group>
      <Input.TextArea
        placeholder="Additional details (optional)"
        value={detail}
        onChange={e => setDetail(e.target.value)}
        autoSize={{ minRows: 2, maxRows: 5 }}
      />
    </Modal>
  );
}

// ── Contacts panel ────────────────────────────────────────────────────────────
// `showAgents` (default true) lets the desktop MessagingPanel hide the agent
// list, since Agent Chat is its own independently dockable panel there.

export default function ContactsPanel({
  user, friends, groups, currentContact,
  onOpen, onAddFriend, onRemoveFriend, onReportUser, onBlockUser, onCreateGroup, onUpdateGroup, onLeaveGroup,
  loaded, onLoad,
  agents, activeAgent, onOpenAgent, onNewAgent,
  showAgents = true,
}) {
  const [friendInput,    setFriendInput]    = useState('');
  const [showAddFriend,  setShowAddFriend]  = useState(false);
  const [friendMsg,      setFriendMsg]      = useState(null); // { type: 'success'|'error', text }
  const [groupModal,     setGroupModal]     = useState(false);
  const [editingGroup,   setEditingGroup]   = useState(null);
  const [reportTarget,   setReportTarget]   = useState(null);
  const [form]                              = Form.useForm();

  const handleBlock = (contact) => {
    Modal.confirm({
      title: `Block ${contact.name}?`,
      content: "They won't be able to contact you or add you as a friend, and their existing content will be removed from your view. We'll be notified so we can review the situation.",
      okText: 'Block', okButtonProps: { danger: true },
      onOk: async () => {
        const ok = await onBlockUser(contact.id);
        antMessage[ok ? 'success' : 'error'](ok ? `${contact.name} has been blocked.` : 'Could not block this user.');
        await onLoad();
      },
    });
  };

  useEffect(() => { if (!loaded) onLoad(); }, []);

  const handleAddFriend = async () => {
    if (!friendInput.trim()) return;
    const result = await onAddFriend(friendInput.trim());
    if (result.ok) {
      setFriendInput('');
      setFriendMsg({ type: 'success', text: 'Friend request sent!' });
      await onLoad();
      setTimeout(() => { setShowAddFriend(false); setFriendMsg(null); }, 1800);
    } else {
      setFriendMsg({ type: 'error', text: result.detail || 'Request failed.' });
    }
  };

  const handleGroupOk = async () => {
    const vals = form.getFieldsValue();
    if (editingGroup) {
      await onUpdateGroup(editingGroup.id, vals.title, vals.members || []);
    } else {
      await onCreateGroup(vals.title, vals.members || []);
    }
    setGroupModal(false);
    setEditingGroup(null);
    form.resetFields();
    await onLoad();
  };

  const openNewGroup = () => { setEditingGroup(null); form.resetFields(); setGroupModal(true); };

  if (!user) {
    return (
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', height: '100%', padding: '1.2rem', textAlign: 'center', gap: '0.8rem' }}>
        <MessageOutlined style={{ fontSize: 22, color: 'rgba(255,198,26,0.35)' }} />
        <Text style={{ fontSize: '0.68rem', color: 'rgba(242,242,242,0.3)', lineHeight: 1.5 }}>Sign in to message study partners.</Text>
      </div>
    );
  }

  const groupList = Object.entries(groups || {});

  return (
    <>
      <div style={{ padding: '0.9rem 0.8rem 0.6rem', borderBottom: '1px solid rgba(255,255,255,0.072)', flexShrink: 0 }}>
        <Text style={{ fontFamily: "'Space Grotesk', sans-serif", fontWeight: 700, fontSize: '0.58rem', letterSpacing: '0.24em', textTransform: 'uppercase', color: 'rgba(255,198,26,0.55)' }}>
          Messages
        </Text>
      </div>

      <div style={{ flex: 1, overflowY: 'auto' }}>
        {/* Friends */}
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0.55rem 0.8rem 0.25rem' }}>
          <Text style={{ fontFamily: "'Space Grotesk', sans-serif", fontWeight: 700, fontSize: '0.52rem', letterSpacing: '0.2em', textTransform: 'uppercase', color: 'rgba(255,198,26,0.4)' }}>Friends</Text>
          <Button type="text" size="small" icon={<UserAddOutlined />} onClick={() => setShowAddFriend(v => !v)}
            style={{ color: 'rgba(255,198,26,0.5)', padding: '0 3px', height: 20 }} />
        </div>
        {showAddFriend && (
          <div style={{ padding: '0.25rem 0.7rem 0.4rem' }}>
            <Input
              size="small" placeholder="Username"
              value={friendInput}
              onChange={e => { setFriendInput(e.target.value); if (friendMsg) setFriendMsg(null); }}
              onPressEnter={handleAddFriend}
              suffix={<Button type="link" size="small" onClick={handleAddFriend} style={{ padding: 0, fontSize: '0.6rem' }}>Add</Button>}
              style={{ fontSize: '0.72rem' }}
            />
            {friendMsg && (
              <div style={{
                marginTop: '0.3rem',
                fontSize: '0.63rem',
                fontFamily: "'Inter', sans-serif",
                color: friendMsg.type === 'success' ? '#6dbf7e' : '#e07070',
                display: 'flex',
                alignItems: 'center',
                gap: '0.3rem',
              }}>
                <span>{friendMsg.type === 'success' ? '✓' : '✕'}</span>
                {friendMsg.text}
              </div>
            )}
          </div>
        )}
        {!loaded
          ? <div style={{ textAlign: 'center', padding: '0.8rem' }}><Spin size="small" /></div>
          : friends.length === 0
            ? <Text style={{ display: 'block', textAlign: 'center', padding: '0.6rem 0.5rem', color: 'rgba(242,242,242,0.2)', fontSize: '0.62rem' }}>No friends yet</Text>
            : friends.map(f => (
                <ContactRow key={f.id} contact={f} active={currentContact?.id === f.id} onOpen={onOpen}
                  onRemove={() => { onRemoveFriend(f.id); onLoad(); }}
                  onReport={setReportTarget} onBlock={handleBlock} />
              ))
        }

        {/* Groups */}
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0.55rem 0.8rem 0.25rem', borderTop: '1px solid rgba(255,255,255,0.048)', marginTop: '0.3rem' }}>
          <Text style={{ fontFamily: "'Space Grotesk', sans-serif", fontWeight: 700, fontSize: '0.52rem', letterSpacing: '0.2em', textTransform: 'uppercase', color: 'rgba(255,198,26,0.4)' }}>Groups</Text>
          <Button type="text" size="small" icon={<PlusOutlined />} onClick={openNewGroup}
            style={{ color: 'rgba(255,198,26,0.5)', padding: '0 3px', height: 20 }} />
        </div>
        {groupList.length === 0
          ? <Text style={{ display: 'block', textAlign: 'center', padding: '0.6rem 0.5rem', color: 'rgba(242,242,242,0.2)', fontSize: '0.62rem' }}>No groups yet</Text>
          : groupList.map(([gid, g]) => {
              const contact = { id: gid, name: g.title || gid.slice(0, 8), type: 'group', toUsers: g.users || [], group_id: gid };
              return (
                <ContactRow key={gid} contact={contact} active={currentContact?.id === gid} onOpen={onOpen}
                  onRemove={() => { onLeaveGroup(gid); onLoad(); }}
                  onEdit={() => { setEditingGroup(contact); form.setFieldsValue({ title: g.title, members: (g.users || []).filter(id => id !== user?.user_id) }); setGroupModal(true); }}
                />
              );
            })
        }

        {/* Agents */}
        {showAgents && (
          <>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0.55rem 0.8rem 0.25rem', borderTop: '1px solid rgba(255,255,255,0.048)', marginTop: '0.3rem' }}>
              <Text style={{ fontFamily: "'Space Grotesk', sans-serif", fontWeight: 700, fontSize: '0.52rem', letterSpacing: '0.2em', textTransform: 'uppercase', color: 'rgba(255,198,26,0.4)' }}>Agents</Text>
              <Button type="text" size="small" icon={<PlusOutlined />} onClick={onNewAgent}
                style={{ color: 'rgba(255,198,26,0.5)', padding: '0 3px', height: 20 }} />
            </div>
            {(agents || []).length === 0
              ? <Text style={{ display: 'block', textAlign: 'center', padding: '0.6rem 0.5rem', color: 'rgba(242,242,242,0.2)', fontSize: '0.62rem' }}>No agent chats yet</Text>
              : (agents || []).filter(a => a.enabled !== false).map(agent => (
                  <AgentRow key={agent.id} agent={agent} active={activeAgent?.id === agent.id} onOpen={() => onOpenAgent(agent)} />
                ))
            }
          </>
        )}
      </div>

      {/* Group modal */}
      <Modal
        open={groupModal}
        title={<Text style={{ fontFamily: "'Space Grotesk', sans-serif", color: 'var(--parchment)' }}>{editingGroup ? 'Edit Group' : 'New Group'}</Text>}
        onOk={handleGroupOk}
        onCancel={() => { setGroupModal(false); setEditingGroup(null); form.resetFields(); }}
        okText={editingGroup ? 'Update' : 'Create'}
      >
        <Form form={form} layout="vertical">
          <Form.Item name="title" label="Group name" rules={[{ required: true }]}>
            <Input placeholder="Study Group" />
          </Form.Item>
          <Form.Item name="members" label="Members">
            <Checkbox.Group style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              {friends.map(f => (
                <Checkbox key={f.id} value={f.id} style={{ color: 'rgba(242,242,242,0.6)' }}>{f.name}</Checkbox>
              ))}
            </Checkbox.Group>
          </Form.Item>
        </Form>
      </Modal>

      <ReportUserModal
        target={reportTarget}
        onSubmit={(id, reason, detail) => onReportUser(id, reason, detail)}
        onClose={() => setReportTarget(null)}
      />
    </>
  );
}
