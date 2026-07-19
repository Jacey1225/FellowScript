import React, { useState, useRef, useEffect } from 'react';
import {
  Button, Input, Avatar, Typography, Space, Empty,
  Spin, Divider, Modal, Form, Checkbox, List,
} from 'antd';
import {
  ArrowLeftOutlined, PlusOutlined, SendOutlined,
  DeleteOutlined, EditOutlined, TeamOutlined,
} from '@ant-design/icons';

const { Text, Title } = Typography;

// ── Contact item ──────────────────────────────────────────────────────────────

function ContactItem({ contact, onOpen, onRemove, onEditGroup }) {
  return (
    <div
      style={{ display: 'flex', alignItems: 'center', gap: '0.65rem', padding: '0.65rem 1.1rem', cursor: 'pointer', borderLeft: '2px solid transparent', transition: 'background 0.18s, border-color 0.18s' }}
      onClick={() => onOpen(contact)}
      onMouseEnter={e => { e.currentTarget.style.background = 'rgba(200,134,26,0.07)'; e.currentTarget.style.borderLeftColor = 'var(--gold)'; }}
      onMouseLeave={e => { e.currentTarget.style.background = ''; e.currentTarget.style.borderLeftColor = 'transparent'; }}
    >
      <Avatar style={{ background: 'rgba(200,134,26,0.15)', border: '1px solid rgba(200,134,26,0.3)', color: 'var(--gold)', fontFamily: "'DM Serif Display', serif", flexShrink: 0 }}>
        {contact.name[0].toUpperCase()}
      </Avatar>
      <div style={{ flex: 1, minWidth: 0 }}>
        <Text style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.82rem', color: 'rgba(244,228,193,0.75)', display: 'block', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {contact.name}
        </Text>
        {contact.preview && (
          <Text style={{ fontSize: '0.68rem', color: 'rgba(244,228,193,0.32)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', display: 'block' }}>
            {contact.preview}
          </Text>
        )}
      </div>
      <Space size={2} onClick={e => e.stopPropagation()}>
        {contact.type === 'group' && (
          <Button type="text" size="small" icon={<EditOutlined />} onClick={() => onEditGroup(contact)}
            style={{ color: 'rgba(200,134,26,0.3)', padding: '0 4px' }} />
        )}
        <Button type="text" size="small" icon={<DeleteOutlined />} onClick={() => onRemove(contact)}
          style={{ color: 'rgba(200,134,26,0.3)', padding: '0 4px' }} />
      </Space>
    </div>
  );
}

// ── Chat view ─────────────────────────────────────────────────────────────────

function ChatView({ contact, messages, groupMembers, user, onBack, onSend }) {
  const [text, setText]           = useState('');
  const [showMembers, setShowMembers] = useState(false);
  const messagesEndRef = useRef(null);

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  const handleSend = () => {
    if (!text.trim()) return;
    onSend(text.trim());
    setText('');
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', flex: 1, minHeight: 0, overflow: 'hidden' }}>
      {/* Chat header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '0.65rem', padding: '0.85rem 1.1rem', borderBottom: '1px solid rgba(200,134,26,0.15)', flexShrink: 0 }}>
        <Button type="text" icon={<ArrowLeftOutlined />} onClick={onBack} style={{ color: 'rgba(200,134,26,0.6)', padding: '0 4px' }} />
        <Text
          strong
          style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.88rem', color: 'var(--parchment)', flex: 1, cursor: contact.type === 'group' ? 'pointer' : 'default' }}
          onClick={() => contact.type === 'group' && setShowMembers(v => !v)}
        >
          {contact.name}
          {contact.type === 'group' && <TeamOutlined style={{ marginLeft: 6, fontSize: '0.75rem', color: 'rgba(200,134,26,0.5)' }} />}
        </Text>
      </div>

      {/* Group members */}
      {showMembers && contact.type === 'group' && (
        <div style={{ borderBottom: '1px solid rgba(200,134,26,0.15)', background: 'rgba(12,7,2,0.6)', padding: '0.85rem 1.1rem', maxHeight: 200, overflowY: 'auto' }}>
          <Text style={{ fontSize: '0.6rem', letterSpacing: '0.15em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.45)', display: 'block', marginBottom: '0.55rem' }}>Members</Text>
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.5rem', marginBottom: '0.4rem' }}>
            <Avatar size={26} style={{ background: 'rgba(200,134,26,0.12)', border: '1px solid rgba(200,134,26,0.25)', color: 'var(--gold)', fontSize: '0.65rem' }}>
              {(user.username || 'Y')[0].toUpperCase()}
            </Avatar>
            <Text style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.78rem', color: 'var(--gold)' }}>{user.username || 'You'} (you)</Text>
          </div>
          {groupMembers.map((m, i) => {
            const uname = m.username || m.user_id?.slice(0, 8) || '?';
            return (
              <div key={i} style={{ display: 'flex', alignItems: 'center', gap: '0.5rem', marginBottom: '0.4rem' }}>
                <Avatar size={26} style={{ background: 'rgba(200,134,26,0.12)', border: '1px solid rgba(200,134,26,0.25)', color: 'var(--gold)', fontSize: '0.65rem' }}>
                  {uname[0].toUpperCase()}
                </Avatar>
                <Text style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.78rem', color: 'rgba(244,228,193,0.7)' }}>{uname}</Text>
              </div>
            );
          })}
        </div>
      )}

      {/* Messages */}
      <div style={{ flex: 1, overflowY: 'auto', padding: '0.75rem 0.9rem', display: 'flex', flexDirection: 'column', gap: '0.5rem' }}>
        {messages.map((m, i) => (
          <div key={i} className={`msg-bubble ${m.mine ? 'sent' : 'received'}`}>
            {!m.mine && m.sender && <div className="msg-bubble-sender">{m.sender}</div>}
            {m.text}
            {m.timestamp && (
              <div className="msg-bubble-meta">
                {new Date(m.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
              </div>
            )}
          </div>
        ))}
        <div ref={messagesEndRef} />
      </div>

      {/* Input */}
      <div style={{ display: 'flex', gap: '0.4rem', padding: '0.7rem 0.8rem', borderTop: '1px solid rgba(200,134,26,0.15)', flexShrink: 0 }}>
        <Input
          value={text}
          onChange={e => setText(e.target.value)}
          onPressEnter={handleSend}
          placeholder="Type a message…"
          style={{ flex: 1 }}
        />
        <Button type="primary" icon={<SendOutlined />} onClick={handleSend} />
      </div>
    </div>
  );
}

// ── Group form modal ──────────────────────────────────────────────────────────

function GroupModal({ open, editGroup, friends, user, onCreate, onUpdate, onClose }) {
  const [form] = Form.useForm();
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (open && editGroup) {
      form.setFieldsValue({ title: editGroup.name || '', members: editGroup.toUsers?.filter(id => id !== user?.user_id) || [] });
    } else if (open) {
      form.resetFields();
    }
  }, [open, editGroup, form, user]);

  const handleOk = async () => {
    const vals = form.getFieldsValue();
    setSaving(true);
    if (editGroup) {
      await onUpdate(editGroup.id, vals.title, vals.members || []);
    } else {
      await onCreate(vals.title, vals.members || []);
    }
    setSaving(false);
    onClose();
  };

  return (
    <Modal
      open={open}
      title={<Text style={{ fontFamily: "'DM Serif Display', serif", color: 'var(--parchment)' }}>{editGroup ? 'Edit Group' : 'New Group'}</Text>}
      onOk={handleOk}
      onCancel={onClose}
      confirmLoading={saving}
      okText={editGroup ? 'Update' : 'Create'}
    >
      <Form form={form} layout="vertical">
        <Form.Item name="title" label="Group name" rules={[{ required: true }]}>
          <Input placeholder="Study Group" />
        </Form.Item>
        <Form.Item name="members" label="Members">
          <Checkbox.Group style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            {friends.map(f => (
              <Checkbox key={f.id} value={f.id} style={{ color: 'rgba(244,228,193,0.6)' }}>{f.name}</Checkbox>
            ))}
          </Checkbox.Group>
        </Form.Item>
      </Form>
    </Modal>
  );
}

// ── Main MessagingSidebar ─────────────────────────────────────────────────────

export default function MessagingSidebar({
  user, friends, groups, currentContact, messages, groupMembers,
  onLoadContacts, onOpenChat, onCloseChat, onSend,
  onAddFriend, onRemoveFriend, onCreateGroup, onUpdateGroup, onLeaveGroup,
  loaded,
}) {
  const [showAddFriend,  setShowAddFriend]  = useState(false);
  const [friendInput,    setFriendInput]    = useState('');
  const [showGroupModal, setShowGroupModal] = useState(false);
  const [editingGroup,   setEditingGroup]   = useState(null);

  useEffect(() => {
    if (!loaded) onLoadContacts();
  }, []);

  const handleAddFriend = async () => {
    if (!friendInput.trim()) return;
    const ok = await onAddFriend(friendInput.trim());
    if (ok) { setFriendInput(''); setShowAddFriend(false); await onLoadContacts(); }
  };

  const handleRemove = async (contact) => {
    if (contact.type === 'friend') { await onRemoveFriend(contact.id); }
    else { await onLeaveGroup(contact.id); }
    await onLoadContacts();
  };

  const handleEditGroup = (contact) => { setEditingGroup(contact); setShowGroupModal(true); };

  if (!user) {
    return (
      <div className="msg-sidebar" style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: '1.2rem', padding: '2rem', textAlign: 'center' }}>
        <Text style={{ fontSize: '0.82rem', color: 'rgba(244,228,193,0.4)', lineHeight: 1.6 }}>Sign in to message your study partners.</Text>
        <Button href="#/signin">Sign In</Button>
      </div>
    );
  }

  return (
    <div className="msg-sidebar" style={{ position: 'relative' }}>
      <div className="msg-resize-handle" />

      {currentContact
        ? <ChatView
            contact={currentContact} messages={messages}
            groupMembers={groupMembers} user={user}
            onBack={onCloseChat} onSend={onSend}
          />
        : <div style={{ display: 'flex', flexDirection: 'column', flex: 1, minHeight: 0 }}>
            {/* Header */}
            <div style={{ padding: '1.2rem 1.2rem 0.8rem', borderBottom: '1px solid rgba(200,134,26,0.15)' }}>
              <Title level={5} style={{ margin: 0, fontFamily: "'DM Serif Display', serif", color: 'var(--parchment)' }}>Messages</Title>
            </div>

            <div style={{ flex: 1, overflowY: 'auto' }}>
              {/* Friends */}
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0.75rem 1.1rem 0.35rem', paddingRight: '1rem' }}>
                <Text style={{ fontSize: '0.58rem', letterSpacing: '0.22em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)' }}>Friends</Text>
                <Button type="text" size="small" icon={<PlusOutlined />} onClick={() => setShowAddFriend(v => !v)}
                  style={{ color: 'var(--gold)', border: '1px solid rgba(200,134,26,0.3)' }} />
              </div>
              {showAddFriend && (
                <div style={{ display: 'flex', gap: '0.4rem', padding: '0.3rem 0.9rem 0.5rem' }}>
                  <Input size="small" placeholder="Username" value={friendInput} onChange={e => setFriendInput(e.target.value)} onPressEnter={handleAddFriend} style={{ flex: 1 }} />
                  <Button size="small" type="primary" onClick={handleAddFriend}>Add</Button>
                </div>
              )}
              {friends.length === 0
                ? <Text style={{ display: 'block', textAlign: 'center', padding: '1.2rem 1rem', color: 'rgba(244,228,193,0.22)', fontSize: '0.72rem' }}>No friends yet.</Text>
                : friends.map(f => (
                    <ContactItem key={f.id} contact={f} onOpen={onOpenChat} onRemove={handleRemove} onEditGroup={() => {}} />
                  ))
              }

              {/* Groups */}
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0.75rem 1.1rem 0.35rem', paddingRight: '1rem' }}>
                <Text style={{ fontSize: '0.58rem', letterSpacing: '0.22em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)' }}>Groups</Text>
                <Button type="text" size="small" icon={<PlusOutlined />} onClick={() => { setEditingGroup(null); setShowGroupModal(true); }}
                  style={{ color: 'var(--gold)', border: '1px solid rgba(200,134,26,0.3)' }} />
              </div>
              {Object.keys(groups).length === 0
                ? <Text style={{ display: 'block', textAlign: 'center', padding: '1.2rem 1rem', color: 'rgba(244,228,193,0.22)', fontSize: '0.72rem' }}>No groups yet.</Text>
                : Object.entries(groups).map(([gid, g]) => {
                    const contact = { id: gid, name: g.title, type: 'group', toUsers: g.users || [], group_id: gid, preview: '' };
                    return <ContactItem key={gid} contact={contact} onOpen={onOpenChat} onRemove={handleRemove} onEditGroup={handleEditGroup} />;
                  })
              }
            </div>
          </div>
      }

      <GroupModal
        open={showGroupModal}
        editGroup={editingGroup}
        friends={friends}
        user={user}
        onCreate={async (title, members) => { await onCreateGroup(title, members); await onLoadContacts(); }}
        onUpdate={async (gid, title, members) => { await onUpdateGroup(gid, title, members); await onLoadContacts(); }}
        onClose={() => { setShowGroupModal(false); setEditingGroup(null); }}
      />
    </div>
  );
}
