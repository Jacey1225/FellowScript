import React, { useEffect, useState, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  Layout, Card, Form, Input, Button, Typography,
  Avatar, Spin, Alert, Divider, Row, Col,
  Switch, Modal, Checkbox,
} from 'antd';
import {
  UserOutlined, MailOutlined, LockOutlined,
  LogoutOutlined, DeleteOutlined, RobotOutlined,
  PlusOutlined, ThunderboltOutlined,
} from '@ant-design/icons';
import AppNav from '../components/AppNav.jsx';
import { useAuth } from '../context/AuthContext.jsx';
import { API } from '../config.js';

const { Content } = Layout;
const { Title, Text, Paragraph } = Typography;

const CARD_STYLE = {
  background: 'rgba(6,4,1,0.88)',
  border: '1px solid rgba(200,134,26,0.16)',
  backdropFilter: 'blur(14px)',
  borderRadius: 14,
  marginBottom: '1.5rem',
};

function StatBox({ value, label }) {
  return (
    <div style={{ textAlign: 'center', padding: '1.1rem 0.5rem' }}>
      <div style={{ fontFamily: "'Playfair Display', serif", fontSize: 'clamp(1.8rem,3vw,2.4rem)', fontWeight: 700, color: 'var(--gold)', lineHeight: 1 }}>
        {value ?? '—'}
      </div>
      <div style={{ fontFamily: "'Lora', serif", fontSize: '0.6rem', letterSpacing: '0.22em', textTransform: 'uppercase', color: 'rgba(244,228,193,0.4)', marginTop: '0.45rem' }}>
        {label}
      </div>
    </div>
  );
}

export default function Account() {
  const { user, signOut, updateUser } = useAuth();
  const navigate = useNavigate();
  const [form] = Form.useForm();

  const [profileData,    setProfileData]    = useState(null);
  const [profileLoading, setProfileLoading] = useState(true);
  const [editLoading,    setEditLoading]    = useState(false);
  const [editMsg,        setEditMsg]        = useState(null);

  const [requests,        setRequests]        = useState([]);
  const [requestsLoading, setRequestsLoading] = useState({});

  const [deleteConfirm,  setDeleteConfirm]  = useState('');
  const [deleteLoading,  setDeleteLoading]  = useState(false);
  const [deleteMsg,      setDeleteMsg]      = useState(null);

  // Agents
  const [agents,          setAgents]          = useState([]);
  const [agentsLoading,   setAgentsLoading]   = useState(false);
  const [agentModal,      setAgentModal]      = useState(false);
  const [newAgentRole,    setNewAgentRole]    = useState('');
  const [agentSaving,     setAgentSaving]     = useState(false);
  const [hbModal,         setHbModal]         = useState(null); // agentId | null
  const [hbDays,          setHbDays]          = useState([]);
  const [hbPrompt,        setHbPrompt]        = useState('');
  const [hbSaving,        setHbSaving]        = useState(false);

  const DAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

  const loadProfile = useCallback(async () => {
    if (!user) { navigate('/signin'); return; }
    setProfileLoading(true);
    try {
      const res  = await fetch(`${API}/user/${user.user_id}`);
      const data = res.ok ? await res.json() : user;
      setProfileData(data);
      form.setFieldsValue({ username: data.username || '', email: data.email || '' });

      const reqIds = data.friend_requests || [];
      const resolved = await Promise.all(reqIds.map(async uid => {
        try {
          const r = await fetch(`${API}/user/${uid}`);
          if (r.ok) { const d = await r.json(); return { uid, username: d.username || uid.slice(0, 8) }; }
        } catch {}
        return { uid, username: uid.slice(0, 8) };
      }));
      setRequests(resolved);
    } catch {
      setProfileData(user);
    } finally {
      setProfileLoading(false);
    }
  }, [user, navigate, form]);

  const loadAgents = useCallback(async () => {
    if (!user) return;
    setAgentsLoading(true);
    try {
      const res = await fetch(`${API}/agent/${user.user_id}`);
      if (res.ok) {
        const data = await res.json();
        setAgents(Object.entries(data).map(([id, a]) => ({ id, ...a })));
      }
    } catch {} finally { setAgentsLoading(false); }
  }, [user]);

  useEffect(() => { loadProfile(); loadAgents(); }, [loadProfile, loadAgents]);

  const handleCreateAgent = async () => {
    setAgentSaving(true);
    try {
      const body = { user_id: user.user_id, chats: [], enabled: true };
      if (newAgentRole.trim()) body.role = newAgentRole.trim();
      const res = await fetch(`${API}/agent/${user.user_id}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
      });
      if (res.ok || res.status === 201) { setAgentModal(false); setNewAgentRole(''); await loadAgents(); }
    } catch {} finally { setAgentSaving(false); }
  };

  const handleToggleAgent = async (agentId, enabled) => {
    try {
      await fetch(`${API}/agent/${user.user_id}/${agentId}`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ enabled }),
      });
      setAgents(prev => prev.map(a => a.id === agentId ? { ...a, enabled } : a));
    } catch {}
  };

  const handleDeleteAgent = async (agentId) => {
    try {
      const res = await fetch(`${API}/agent/${user.user_id}/${agentId}`, { method: 'DELETE' });
      if (res.ok || res.status === 204) setAgents(prev => prev.filter(a => a.id !== agentId));
    } catch {}
  };

  const handleAddHeartbeat = async () => {
    if (!hbModal || !hbPrompt.trim() || !hbDays.length) return;
    setHbSaving(true);
    try {
      await fetch(`${API}/agent/${user.user_id}/${hbModal}/heartbeat`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          agent_id: hbModal, user_id: user.user_id,
          days_per_week: hbDays, prompt: hbPrompt.trim(),
          timestamp: new Date().toISOString(),
        }),
      });
      setHbModal(null); setHbDays([]); setHbPrompt('');
    } catch {} finally { setHbSaving(false); }
  };

  const handleSave = async (vals) => {
    setEditMsg(null);
    const body = {};
    if (vals.username && vals.username !== profileData?.username) body.username   = vals.username.trim();
    if (vals.email    && vals.email    !== profileData?.email)    body.email      = vals.email.trim();
    if (vals.password)                                            body.plain_pass = vals.password;

    if (Object.keys(body).length === 0) {
      setEditMsg({ type: 'warning', text: 'No changes to save.' });
      return;
    }
    setEditLoading(true);
    try {
      const res  = await fetch(`${API}/user/${user.user_id}`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      const data = await res.json();
      if (!res.ok) { setEditMsg({ type: 'error', text: data.detail || 'Update failed.' }); return; }
      updateUser(data);
      setProfileData(prev => ({ ...prev, ...data }));
      form.setFieldValue('password', '');
      setEditMsg({ type: 'success', text: 'Profile updated.' });
    } catch {
      setEditMsg({ type: 'error', text: 'Could not reach the server.' });
    } finally {
      setEditLoading(false);
    }
  };

  const handleAccept = async (uid, username) => {
    setRequestsLoading(prev => ({ ...prev, [uid]: true }));
    try {
      const res = await fetch(
        `${API}/friends/${user.user_id}/add?friend_username=${encodeURIComponent(username)}`,
        { method: 'POST' }
      );
      if (res.ok || res.status === 204) {
        setRequests(prev => prev.filter(r => r.uid !== uid));
      }
    } catch {}
    setRequestsLoading(prev => ({ ...prev, [uid]: false }));
  };

  const handleDelete = async () => {
    setDeleteMsg(null);
    const expected = profileData?.username || user?.username;
    if (!deleteConfirm) { setDeleteMsg({ type: 'error', text: 'Please type your username to confirm.' }); return; }
    if (deleteConfirm !== expected) { setDeleteMsg({ type: 'error', text: `Username doesn't match. Expected: ${expected}` }); return; }
    setDeleteLoading(true);
    try {
      const res = await fetch(`${API}/user/${user.user_id}`, { method: 'DELETE' });
      if (res.ok || res.status === 204) { signOut(); navigate('/signin'); }
      else { setDeleteMsg({ type: 'error', text: 'Delete failed. Please try again.' }); }
    } catch {
      setDeleteMsg({ type: 'error', text: 'Could not reach the server.' });
    } finally {
      setDeleteLoading(false);
    }
  };

  const handleSignOut = () => { signOut(); navigate('/signin'); };

  if (!user) return null;

  const data = profileData || user;

  return (
    <Layout style={{ minHeight: '100vh', background: 'transparent' }}>
      <AppNav />

      <Content style={{ paddingTop: 'calc(var(--nav-h) + 2.5rem)', paddingBottom: '5rem', paddingLeft: '2rem', paddingRight: '2rem', maxWidth: 680, margin: '0 auto', width: '100%' }}>

        {/* Header */}
        <div style={{ marginBottom: '2rem', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.6rem', letterSpacing: '0.32em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.55)', display: 'block', marginBottom: '0.2rem' }}>
            Your Profile
          </Text>
          <Title level={2} style={{ margin: 0, fontFamily: "'Playfair Display', serif", color: 'var(--parchment)' }}>
            {profileLoading ? 'Account' : <>{data.username || 'Account'}</>}
          </Title>
        </div>

        {/* Stats */}
        <Card style={{ ...CARD_STYLE, animationDelay: '0.08s', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.56rem', letterSpacing: '0.3em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)', display: 'block', marginBottom: '0.4rem' }}>
            Overview
          </Text>
          {profileLoading
            ? <div style={{ textAlign: 'center', padding: '2rem' }}><Spin /></div>
            : <Row>
                <Col span={6}><StatBox value={(data.friends      || []).length}         label="Friends"    /></Col>
                <Col span={6}><StatBox value={(data.groups       || []).length}         label="Groups"     /></Col>
                <Col span={6}><StatBox value={Object.keys(data.notes      || {}).length} label="Notes"      /></Col>
                <Col span={6}><StatBox value={Object.keys(data.highlights || {}).length} label="Highlights" /></Col>
              </Row>
          }
        </Card>

        {/* Edit profile */}
        <Card style={{ ...CARD_STYLE, animationDelay: '0.16s', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.56rem', letterSpacing: '0.3em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)', display: 'block', marginBottom: '1rem' }}>
            Edit Profile
          </Text>
          {editMsg && <Alert type={editMsg.type} message={editMsg.text} showIcon style={{ marginBottom: 16, borderRadius: 8 }} />}
          <Form form={form} layout="vertical" onFinish={handleSave}>
            <Form.Item name="username" label="Username">
              <Input prefix={<UserOutlined />} placeholder="yourname" />
            </Form.Item>
            <Form.Item name="email" label="Email" rules={[{ type: 'email', message: 'Enter a valid email' }]}>
              <Input prefix={<MailOutlined />} placeholder="you@example.com" />
            </Form.Item>
            <Form.Item name="password" label="New Password" extra="Leave blank to keep current password.">
              <Input.Password prefix={<LockOutlined />} placeholder="New password…" />
            </Form.Item>
            <Button type="primary" htmlType="submit" loading={editLoading} style={{ borderRadius: 8, fontFamily: "'Lora', serif", letterSpacing: '0.08em' }}>
              Save Changes
            </Button>
          </Form>
        </Card>

        {/* Friend requests */}
        <Card style={{ ...CARD_STYLE, animationDelay: '0.24s', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.56rem', letterSpacing: '0.3em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)', display: 'block', marginBottom: '0.8rem' }}>
            Friend Requests
          </Text>
          {profileLoading
            ? <Spin size="small" />
            : requests.length === 0
              ? <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.28)' }}>No pending friend requests.</Text>
              : requests.map(({ uid, username }) => (
                  <div key={uid} style={{ display: 'flex', alignItems: 'center', gap: '0.75rem', padding: '0.6rem 0', borderBottom: '1px solid rgba(200,134,26,0.08)' }}>
                    <Avatar style={{ background: 'rgba(200,134,26,0.15)', border: '1px solid rgba(200,134,26,0.3)', color: 'var(--gold)', fontFamily: "'Playfair Display', serif" }}>
                      {username[0].toUpperCase()}
                    </Avatar>
                    <div style={{ flex: 1 }}>
                      <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.84rem', color: 'var(--parchment)', display: 'block' }}>{username}</Text>
                      <Text style={{ fontSize: '0.68rem', color: 'rgba(244,228,193,0.35)' }}>Wants to be your friend</Text>
                    </div>
                    <Button
                      size="small" type="primary"
                      loading={requestsLoading[uid]}
                      onClick={() => handleAccept(uid, username)}
                      style={{ borderRadius: 8, fontFamily: "'Lora', serif" }}
                    >
                      Accept
                    </Button>
                  </div>
                ))
          }
        </Card>

        {/* Agents */}
        <Card style={{ ...CARD_STYLE, animationDelay: '0.32s', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '0.8rem' }}>
            <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.56rem', letterSpacing: '0.3em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)' }}>
              Agents
            </Text>
            <Button size="small" type="text" icon={<PlusOutlined />} onClick={() => { setNewAgentRole(''); setAgentModal(true); }}
              style={{ color: 'rgba(200,134,26,0.6)', fontSize: '0.7rem' }}>
              New Agent
            </Button>
          </div>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.74rem', color: 'rgba(244,228,193,0.35)', display: 'block', marginBottom: '1rem', lineHeight: 1.65 }}>
            Enabled agents participate in your chats and can summarize study sessions. Disabled agents are hidden from the messaging sidebar.
          </Text>
          {agentsLoading
            ? <Spin size="small" />
            : agents.length === 0
              ? <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.28)' }}>No agents yet. Create one to get started.</Text>
              : agents.map(agent => {
                  const label = !agent.role || agent.role.startsWith('You are a spiritual') ? 'Spiritual Guide' : agent.role.split('\n').find(l => l.trim())?.slice(0, 28) || 'Agent';
                  return (
                    <div key={agent.id} style={{ padding: '0.75rem 0', borderBottom: '1px solid rgba(200,134,26,0.08)' }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem' }}>
                        <div style={{ width: 36, height: 36, borderRadius: '50%', background: 'rgba(200,134,26,0.1)', border: '1px solid rgba(200,134,26,0.25)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
                          <RobotOutlined style={{ color: 'var(--gold)', fontSize: '0.95rem' }} />
                        </div>
                        <div style={{ flex: 1 }}>
                          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.84rem', color: 'var(--parchment)', display: 'block' }}>{label}</Text>
                          <Text style={{ fontSize: '0.64rem', color: 'rgba(244,228,193,0.3)', fontFamily: "'Lora', serif" }}>
                            {agent.role ? agent.role.slice(0, 60) + (agent.role.length > 60 ? '…' : '') : 'Default spiritual guide role'}
                          </Text>
                        </div>
                        <Switch
                          size="small"
                          checked={agent.enabled !== false}
                          onChange={enabled => handleToggleAgent(agent.id, enabled)}
                          title={agent.enabled !== false ? 'Enabled' : 'Disabled'}
                        />
                        <Button
                          size="small" type="text"
                          icon={<ThunderboltOutlined />}
                          onClick={() => { setHbModal(agent.id); setHbDays([]); setHbPrompt(''); }}
                          style={{ color: 'rgba(200,134,26,0.55)', padding: '0 4px' }}
                          title="Add heartbeat"
                        />
                        <Button
                          size="small" type="text" danger
                          icon={<DeleteOutlined />}
                          onClick={() => handleDeleteAgent(agent.id)}
                          style={{ padding: '0 4px' }}
                        />
                      </div>
                    </div>
                  );
                })
          }
        </Card>

        {/* New agent modal */}
        <Modal
          open={agentModal}
          title={<Text style={{ fontFamily: "'Playfair Display', serif", color: 'var(--parchment)' }}>New Agent</Text>}
          onCancel={() => setAgentModal(false)}
          onOk={handleCreateAgent}
          okText="Create"
          confirmLoading={agentSaving}
        >
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'rgba(244,228,193,0.55)', display: 'block', marginBottom: '0.6rem' }}>
            Optionally give this agent a custom role. Leave blank to use the default spiritual guide role.
          </Text>
          <Input.TextArea
            placeholder="e.g. You are a focused study partner specialising in New Testament theology…"
            value={newAgentRole}
            onChange={e => setNewAgentRole(e.target.value)}
            autoSize={{ minRows: 3, maxRows: 8 }}
            style={{ fontSize: '0.82rem' }}
          />
        </Modal>

        {/* Heartbeat modal */}
        <Modal
          open={!!hbModal}
          title={<Text style={{ fontFamily: "'Playfair Display', serif", color: 'var(--parchment)' }}>Add Heartbeat</Text>}
          onCancel={() => setHbModal(null)}
          onOk={handleAddHeartbeat}
          okText="Schedule"
          confirmLoading={hbSaving}
          okButtonProps={{ disabled: !hbPrompt.trim() || !hbDays.length }}
        >
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'rgba(244,228,193,0.55)', display: 'block', marginBottom: '0.8rem' }}>
            Schedule a recurring prompt — the agent will check in on these days with the message you define.
          </Text>
          <div style={{ marginBottom: '1rem' }}>
            <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.72rem', color: 'rgba(244,228,193,0.5)', display: 'block', marginBottom: '0.4rem' }}>Days</Text>
            <Checkbox.Group value={hbDays} onChange={setHbDays} style={{ display: 'flex', flexWrap: 'wrap', gap: '6px 12px' }}>
              {DAYS.map(d => <Checkbox key={d} value={d} style={{ color: 'rgba(244,228,193,0.7)', fontSize: '0.78rem' }}>{d.slice(0, 3)}</Checkbox>)}
            </Checkbox.Group>
          </div>
          <div>
            <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.72rem', color: 'rgba(244,228,193,0.5)', display: 'block', marginBottom: '0.4rem' }}>Prompt</Text>
            <Input.TextArea
              placeholder="e.g. Send me a daily scripture verse and a reflection question."
              value={hbPrompt}
              onChange={e => setHbPrompt(e.target.value)}
              autoSize={{ minRows: 2, maxRows: 5 }}
              style={{ fontSize: '0.82rem' }}
            />
          </div>
        </Modal>

        {/* Sign out */}
        <Button
          block size="large" icon={<LogoutOutlined />}
          onClick={handleSignOut}
          style={{ marginBottom: '1.5rem', borderRadius: 8, fontFamily: "'Lora', serif", letterSpacing: '0.1em', textTransform: 'uppercase', animation: 'fadeUp 0.55s ease 0.32s forwards', opacity: 0 }}
        >
          Sign Out
        </Button>

        {/* Danger zone */}
        <Card
          style={{ ...CARD_STYLE, borderColor: 'rgba(220,50,50,0.25)', background: 'rgba(40,8,8,0.75)', animationDelay: '0.40s', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}
        >
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.56rem', letterSpacing: '0.3em', textTransform: 'uppercase', color: 'rgba(220,80,80,0.7)', display: 'block', marginBottom: '0.5rem' }}>
            Danger Zone
          </Text>
          <Paragraph style={{ fontFamily: "'Lora', serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.45)', lineHeight: 1.75, marginBottom: '1.2rem' }}>
            Permanently deletes your account, all notes, highlights, and removes you from all groups and friend lists. This cannot be undone.
          </Paragraph>
          {deleteMsg && <Alert type={deleteMsg.type} message={deleteMsg.text} showIcon style={{ marginBottom: 12, borderRadius: 8 }} />}
          <div style={{ marginBottom: '0.8rem' }}>
            <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.72rem', color: 'rgba(244,228,193,0.5)', display: 'block', marginBottom: '0.4rem' }}>
              Type your username to confirm
            </Text>
            <Input
              value={deleteConfirm}
              onChange={e => setDeleteConfirm(e.target.value)}
              placeholder={profileData?.username || user?.username || 'yourname'}
              style={{ maxWidth: 260, borderRadius: 8 }}
            />
          </div>
          <Button
            danger icon={<DeleteOutlined />}
            loading={deleteLoading}
            onClick={handleDelete}
            style={{ borderRadius: 8, fontFamily: "'Lora', serif" }}
          >
            Delete My Account
          </Button>
        </Card>
      </Content>
    </Layout>
  );
}
