import React, { useEffect, useState, useCallback } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import {
  Layout, Card, Form, Input, Button, Typography,
  Avatar, Spin, Alert, Divider, Row, Col,
  Switch, Modal, Checkbox, Select, TimePicker,
} from 'antd';
import {
  UserOutlined, MailOutlined, LockOutlined,
  LogoutOutlined, DeleteOutlined, RobotOutlined,
  PlusOutlined, ThunderboltOutlined, EditOutlined,
  CheckOutlined, CloseOutlined, CalendarOutlined,
} from '@ant-design/icons';
import dayjs from 'dayjs';
import utc from 'dayjs/plugin/utc';
import AppNav from '../components/AppNav.jsx';
import { useAuth } from '../context/AuthContext.jsx';
import { API } from '../config.js';

dayjs.extend(utc);

const { Content } = Layout;
const { Title, Text, Paragraph } = Typography;

const CARD_STYLE = {
  background: 'rgba(6,4,1,0.88)',
  border: '1px solid rgba(200,134,26,0.16)',
  backdropFilter: 'blur(14px)',
  borderRadius: 14,
  marginBottom: '1.5rem',
};

const WEEKDAYS = [
  { label: 'Sun', value: 0 },
  { label: 'Mon', value: 1 },
  { label: 'Tue', value: 2 },
  { label: 'Wed', value: 3 },
  { label: 'Thu', value: 4 },
  { label: 'Fri', value: 5 },
  { label: 'Sat', value: 6 },
];

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

// Converts local "HH:mm" from a dayjs object → UTC "HH:mm" string
function toUTCTime(dayjsVal) {
  return dayjsVal.utc().format('HH:mm');
}

// Builds a 31-slot timestamps array using UTC time
function buildTimestamps(recurrence, weekdays, monthDays, utcTime) {
  const ts = Array(31).fill(null);
  if (recurrence === 'daily') return Array(31).fill(utcTime);
  if (recurrence === 'weekly') {
    const now = new Date();
    const daysInMonth = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();
    for (let d = 1; d <= daysInMonth; d++) {
      const dow = new Date(now.getFullYear(), now.getMonth(), d).getDay();
      if (weekdays.includes(dow)) ts[d - 1] = utcTime;
    }
    return ts;
  }
  if (recurrence === 'monthly') {
    for (const d of monthDays) if (d >= 1 && d <= 31) ts[d - 1] = utcTime;
    return ts;
  }
  return ts;
}

function scheduleSummary(timestamps) {
  const n = (timestamps || []).filter(Boolean).length;
  if (n === 0)  return 'Not scheduled';
  if (n >= 30)  return 'Every day';
  return `${n} day${n === 1 ? '' : 's'} / month`;
}

export default function Account() {
  const { user, signOut, updateUser } = useAuth();
  const navigate = useNavigate();
  const [form] = Form.useForm();

  const [profileData,    setProfileData]    = useState(null);
  const [profileLoading, setProfileLoading] = useState(true);
  const [editLoading,    setEditLoading]    = useState(false);
  const [editMsg,        setEditMsg]        = useState(null);
  const [notesCount,     setNotesCount]     = useState(0);
  const [versesCount,    setVersesCount]    = useState(0);

  const [requests,        setRequests]        = useState([]);
  const [requestsLoading, setRequestsLoading] = useState({});

  const [deleteConfirm,  setDeleteConfirm]  = useState('');
  const [deleteLoading,  setDeleteLoading]  = useState(false);
  const [deleteMsg,      setDeleteMsg]      = useState(null);

  // Agents
  const [agents,        setAgents]        = useState([]);
  const [agentsLoading, setAgentsLoading] = useState(false);
  const [agentModal,    setAgentModal]    = useState(false);
  const [newAgentRole,  setNewAgentRole]  = useState('');
  const [agentSaving,   setAgentSaving]   = useState(false);
  const [renamingId,    setRenamingId]    = useState(null);
  const [renameVal,     setRenameVal]     = useState('');

  // Events (heartbeats — flat list across all agents)
  const [events,      setEvents]      = useState([]);
  const [evModal,     setEvModal]     = useState(false);
  const [evStep,      setEvStep]      = useState(0); // 0=recurrence, 1=days, 2=details
  const [evRecur,     setEvRecur]     = useState('daily');
  const [evWeekdays,  setEvWeekdays]  = useState([]);
  const [evMonthDays, setEvMonthDays] = useState([]);
  const [evTime,      setEvTime]      = useState(dayjs());
  const [evAgentId,   setEvAgentId]   = useState('');
  const [evPrompt,    setEvPrompt]    = useState('');
  const [evSaving,    setEvSaving]    = useState(false);

  const loadProfile = useCallback(async () => {
    if (!user) { navigate('/signin'); return; }
    setProfileLoading(true);
    try {
      const [profileRes, notesRes, hlRes] = await Promise.all([
        fetch(`${API}/user/${user.user_id}`),
        fetch(`${API}/notes/${user.user_id}`),
        fetch(`${API}/notes/highlight/${user.user_id}`),
      ]);
      const data = profileRes.ok ? await profileRes.json() : user;
      setProfileData(data);
      form.setFieldsValue({ username: data.username || '', email: data.email || '' });

      if (notesRes.ok) {
        const notesData = await notesRes.json();
        setNotesCount(Object.keys(notesData || {}).length);
      }
      if (hlRes.ok) {
        const hlData = await hlRes.json();
        setVersesCount(Object.keys(hlData || {}).length);
      }

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
        const list = Object.entries(data).map(([id, a]) => ({ id, ...a }));
        setAgents(list);
        if (list.length > 0) setEvAgentId(list[0].id);

        // Load events flat across all agents
        const hbResults = await Promise.all(
          list.map(async agent => {
            try {
              const r = await fetch(`${API}/agent/${user.user_id}/${agent.id}/heartbeats`);
              const hbs = r.ok ? await r.json() : [];
              return hbs.map(hb => ({ ...hb, agent_id: agent.id }));
            } catch { return []; }
          })
        );
        setEvents(hbResults.flat());
      }
    } catch {} finally { setAgentsLoading(false); }
  }, [user]);

  useEffect(() => { loadProfile(); loadAgents(); }, [loadProfile, loadAgents]);

  const agentLabel = (agent) =>
    agent.name ||
    (!agent.role || agent.role.startsWith('You are a spiritual')
      ? 'Spiritual Guide'
      : agent.role.split('\n').find(l => l.trim())?.slice(0, 28) || 'Agent');

  // ── Agent handlers ────────────────────────────────────────────────────────

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

  const handleRenameAgent = async (agentId, name) => {
    const trimmed = name.trim();
    setAgents(prev => prev.map(a => a.id === agentId ? { ...a, name: trimmed } : a));
    setRenamingId(null);
    try {
      await fetch(`${API}/agent/${user.user_id}/${agentId}`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: trimmed }),
      });
    } catch {}
  };

  const handleDeleteAgent = async (agentId) => {
    try {
      const res = await fetch(`${API}/agent/${user.user_id}/${agentId}`, { method: 'DELETE' });
      if (res.ok || res.status === 204) {
        setAgents(prev => prev.filter(a => a.id !== agentId));
        setEvents(prev => prev.filter(e => e.agent_id !== agentId));
      }
    } catch {}
  };

  // ── Event handlers ────────────────────────────────────────────────────────

  const openEventModal = () => {
    setEvStep(0);
    setEvRecur('daily');
    setEvWeekdays([]);
    setEvMonthDays([]);
    setEvTime(dayjs());
    setEvAgentId(agents[0]?.id || '');
    setEvPrompt('');
    setEvModal(true);
  };

  const handleCreateEvent = async () => {
    if (!evAgentId || !evPrompt.trim()) return;
    setEvSaving(true);
    try {
      const utcTime = toUTCTime(evTime);
      const timestamps = buildTimestamps(evRecur, evWeekdays, evMonthDays, utcTime);
      const body = { timestamps, prompt: evPrompt.trim() };
      const res = await fetch(`${API}/agent/${user.user_id}/${evAgentId}/heartbeat`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
      });
      if (res.ok || res.status === 201) {
        setEvModal(false);
        await loadAgents();
      }
    } catch {} finally { setEvSaving(false); }
  };

  const handleDeleteEvent = async (event) => {
    setEvents(prev => prev.filter(e => e._id !== event._id));
    try {
      await fetch(`${API}/agent/${user.user_id}/${event.agent_id}/heartbeat/${event._id}`, { method: 'DELETE' });
    } catch {}
  };

  // ── Profile / account handlers ────────────────────────────────────────────

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
      if (res.ok || res.status === 204) setRequests(prev => prev.filter(r => r.uid !== uid));
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

  // ── Event modal step content ───────────────────────────────────────────────

  const evModalTitle = ['How often?', 'Select Days', 'Event Details'][evStep];

  const evModalContent = () => {
    if (evStep === 0) {
      const opts = [
        { key: 'daily',   icon: '☀️', title: 'Daily',   desc: 'Every day of the month' },
        { key: 'weekly',  icon: '📅', title: 'Weekly',  desc: 'Selected days of the week' },
        { key: 'monthly', icon: '🗓️', title: 'Monthly', desc: 'Selected days of the month' },
      ];
      return (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {opts.map(o => (
            <button key={o.key} onClick={() => { setEvRecur(o.key); setEvStep(o.key === 'daily' ? 2 : 1); }}
              style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '0.75rem 1rem', background: 'rgba(200,134,26,0.07)', border: '1px solid rgba(200,134,26,0.2)', borderRadius: 10, cursor: 'pointer', textAlign: 'left', width: '100%' }}>
              <span style={{ fontSize: '1.3rem' }}>{o.icon}</span>
              <div>
                <div style={{ fontFamily: "'Lora', serif", color: 'var(--parchment)', fontSize: '0.88rem' }}>{o.title}</div>
                <div style={{ fontFamily: "'Lora', serif", color: 'rgba(244,228,193,0.4)', fontSize: '0.72rem' }}>{o.desc}</div>
              </div>
            </button>
          ))}
        </div>
      );
    }

    if (evStep === 1 && evRecur === 'weekly') {
      return (
        <div>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.75rem', color: 'rgba(244,228,193,0.5)', display: 'block', marginBottom: '0.75rem' }}>
            Which days of the week?
          </Text>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
            {WEEKDAYS.map(d => {
              const sel = evWeekdays.includes(d.value);
              return (
                <button key={d.value} onClick={() => setEvWeekdays(prev => sel ? prev.filter(x => x !== d.value) : [...prev, d.value])}
                  style={{ padding: '6px 14px', borderRadius: 8, border: `1px solid ${sel ? 'var(--gold)' : 'rgba(200,134,26,0.2)'}`, background: sel ? 'rgba(200,134,26,0.2)' : 'transparent', color: sel ? 'var(--gold)' : 'rgba(244,228,193,0.6)', fontFamily: "'Lora', serif", fontSize: '0.78rem', cursor: 'pointer' }}>
                  {d.label}
                </button>
              );
            })}
          </div>
        </div>
      );
    }

    if (evStep === 1 && evRecur === 'monthly') {
      return (
        <div>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.75rem', color: 'rgba(244,228,193,0.5)', display: 'block', marginBottom: '0.75rem' }}>
            Which days of the month?
          </Text>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)', gap: 6 }}>
            {Array.from({ length: 31 }, (_, i) => i + 1).map(d => {
              const sel = evMonthDays.includes(d);
              return (
                <button key={d} onClick={() => setEvMonthDays(prev => sel ? prev.filter(x => x !== d) : [...prev, d])}
                  style={{ aspectRatio: '1', borderRadius: 6, border: `1px solid ${sel ? 'var(--gold)' : 'rgba(200,134,26,0.15)'}`, background: sel ? 'rgba(200,134,26,0.2)' : 'transparent', color: sel ? 'var(--gold)' : 'rgba(244,228,193,0.6)', fontFamily: "'Lora', serif", fontSize: '0.7rem', cursor: 'pointer' }}>
                  {d}
                </button>
              );
            })}
          </div>
        </div>
      );
    }

    // Step 2: details
    return (
      <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
        {agents.length > 1 && (
          <div>
            <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.7rem', letterSpacing: '0.2em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.55)', display: 'block', marginBottom: 6 }}>Agent</Text>
            <Select value={evAgentId} onChange={setEvAgentId} style={{ width: '100%' }}
              options={agents.map(a => ({ value: a.id, label: agentLabel(a) }))} />
          </div>
        )}
        <div>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.7rem', letterSpacing: '0.2em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.55)', display: 'block', marginBottom: 6 }}>Event Time</Text>
          <TimePicker value={evTime} onChange={v => v && setEvTime(v)} format="HH:mm" use12Hours={false} style={{ width: '100%' }} />
        </div>
        <div>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.7rem', letterSpacing: '0.2em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.55)', display: 'block', marginBottom: 6 }}>Prompt</Text>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.72rem', color: 'rgba(244,228,193,0.35)', display: 'block', marginBottom: 8 }}>
            The agent will respond to this prompt when the event fires and save the response as a note.
          </Text>
          <Input.TextArea
            value={evPrompt} onChange={e => setEvPrompt(e.target.value)}
            placeholder="e.g. Write a brief devotion on today's theme…"
            autoSize={{ minRows: 3, maxRows: 6 }}
            style={{ fontSize: '0.82rem' }}
          />
        </div>
      </div>
    );
  };

  const evModalFooter = () => {
    if (evStep === 0) return [<Button key="cancel" onClick={() => setEvModal(false)}>Cancel</Button>];
    if (evStep === 1) {
      const canNext = evRecur === 'weekly' ? evWeekdays.length > 0 : evMonthDays.length > 0;
      return [
        <Button key="back" onClick={() => setEvStep(0)}>Back</Button>,
        <Button key="next" type="primary" disabled={!canNext} onClick={() => setEvStep(2)}>Next</Button>,
      ];
    }
    return [
      <Button key="back" onClick={() => setEvStep(evRecur === 'daily' ? 0 : 1)}>Back</Button>,
      <Button key="save" type="primary" loading={evSaving}
        disabled={!evPrompt.trim() || !evAgentId}
        onClick={handleCreateEvent}>Save</Button>,
    ];
  };

  // ── Render ─────────────────────────────────────────────────────────────────

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
                <Col span={6}><StatBox value={(data.friends || []).length} label="Friends" /></Col>
                <Col span={6}><StatBox value={(data.groups  || []).length} label="Groups"  /></Col>
                <Col span={6}><StatBox value={notesCount}                  label="Notes"   /></Col>
                <Col span={6}><StatBox value={versesCount}                 label="Verses"  /></Col>
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
                    <Button size="small" type="primary" loading={requestsLoading[uid]}
                      onClick={() => handleAccept(uid, username)}
                      style={{ borderRadius: 8, fontFamily: "'Lora', serif" }}>
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
            Enabled agents participate in your chats and can summarize study sessions.
          </Text>
          {agentsLoading
            ? <Spin size="small" />
            : agents.length === 0
              ? <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.28)' }}>No agents yet. Create one to get started.</Text>
              : agents.map(agent => {
                  const label = agentLabel(agent);
                  const isRenaming = renamingId === agent.id;
                  return (
                    <div key={agent.id} style={{ padding: '0.75rem 0', borderBottom: '1px solid rgba(200,134,26,0.08)' }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem' }}>
                        <div style={{ width: 36, height: 36, borderRadius: '50%', background: 'rgba(200,134,26,0.1)', border: '1px solid rgba(200,134,26,0.25)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
                          <RobotOutlined style={{ color: 'var(--gold)', fontSize: '0.95rem' }} />
                        </div>
                        <div style={{ flex: 1 }}>
                          {isRenaming ? (
                            <Input size="small" autoFocus value={renameVal}
                              onChange={e => setRenameVal(e.target.value)}
                              onPressEnter={() => handleRenameAgent(agent.id, renameVal)}
                              style={{ fontSize: '0.82rem', width: '100%' }} />
                          ) : (
                            <>
                              <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.84rem', color: 'var(--parchment)', display: 'block' }}>{label}</Text>
                              <Text style={{ fontSize: '0.64rem', color: 'rgba(244,228,193,0.3)', fontFamily: "'Lora', serif" }}>
                                {agent.role ? agent.role.slice(0, 60) + (agent.role.length > 60 ? '…' : '') : 'Default spiritual guide role'}
                              </Text>
                            </>
                          )}
                        </div>
                        {isRenaming ? (
                          <>
                            <Button size="small" type="text" icon={<CheckOutlined />}
                              onClick={() => handleRenameAgent(agent.id, renameVal)}
                              style={{ color: 'var(--gold)', padding: '0 4px' }} />
                            <Button size="small" type="text" icon={<CloseOutlined />}
                              onClick={() => setRenamingId(null)}
                              style={{ color: 'rgba(244,228,193,0.4)', padding: '0 4px' }} />
                          </>
                        ) : (
                          <>
                            <Switch size="small" checked={agent.enabled !== false}
                              onChange={enabled => handleToggleAgent(agent.id, enabled)}
                              title={agent.enabled !== false ? 'Enabled' : 'Disabled'} />
                            <Button size="small" type="text" icon={<EditOutlined />}
                              onClick={() => { setRenamingId(agent.id); setRenameVal(agent.name || label); }}
                              style={{ color: 'rgba(200,134,26,0.55)', padding: '0 4px' }} title="Rename agent" />
                            <Button size="small" type="text" danger icon={<DeleteOutlined />}
                              onClick={() => handleDeleteAgent(agent.id)}
                              style={{ padding: '0 4px' }} />
                          </>
                        )}
                      </div>
                    </div>
                  );
                })
          }
        </Card>

        {/* Events */}
        <Card style={{ ...CARD_STYLE, animationDelay: '0.38s', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '0.8rem' }}>
            <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.56rem', letterSpacing: '0.3em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)' }}>
              Events
            </Text>
            <Button size="small" type="text" icon={<PlusOutlined />}
              onClick={openEventModal}
              disabled={agents.length === 0}
              style={{ color: 'rgba(200,134,26,0.6)', fontSize: '0.7rem' }}>
              New Event
            </Button>
          </div>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.74rem', color: 'rgba(244,228,193,0.35)', display: 'block', marginBottom: '1rem', lineHeight: 1.65 }}>
            Scheduled events trigger an agent to write a note automatically at the set time.
          </Text>
          {agentsLoading
            ? <Spin size="small" />
            : events.length === 0
              ? <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.28)' }}>
                  {agents.length === 0 ? 'Create an agent first to add events.' : 'No events yet. Add one to get started.'}
                </Text>
              : events.map(ev => {
                  const agent = agents.find(a => a.id === ev.agent_id);
                  return (
                    <div key={ev._id} style={{ display: 'flex', alignItems: 'center', gap: '0.75rem', padding: '0.65rem 0', borderBottom: '1px solid rgba(200,134,26,0.08)' }}>
                      <div style={{ width: 30, height: 30, borderRadius: '50%', background: 'rgba(200,134,26,0.1)', border: '1px solid rgba(200,134,26,0.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
                        <ThunderboltOutlined style={{ color: 'var(--gold)', fontSize: '0.75rem' }} />
                      </div>
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.82rem', color: 'var(--parchment)', display: 'block', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                          {ev.prompt || 'Untitled Event'}
                        </Text>
                        <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.65rem', color: 'rgba(244,228,193,0.35)' }}>
                          {scheduleSummary(ev.timestamps)}{agent ? ` · ${agentLabel(agent)}` : ''}
                        </Text>
                      </div>
                      <Button size="small" type="text" danger icon={<DeleteOutlined style={{ fontSize: '0.7rem' }} />}
                        onClick={() => handleDeleteEvent(ev)}
                        style={{ padding: '0 4px', opacity: 0.65, flexShrink: 0 }} />
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

        {/* New event modal */}
        <Modal
          open={evModal}
          title={<Text style={{ fontFamily: "'Playfair Display', serif", color: 'var(--parchment)' }}>{evModalTitle}</Text>}
          onCancel={() => setEvModal(false)}
          footer={evModalFooter()}
          destroyOnClose
        >
          {evModalContent()}
        </Modal>

        {/* Legal links */}
        <div style={{ display: 'flex', justifyContent: 'center', gap: '2rem', marginBottom: '1.5rem' }}>
          <Link to="/privacy" style={{ fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'rgba(244,228,193,0.35)', textDecoration: 'none' }}>
            Privacy Policy
          </Link>
          <Link to="/terms" style={{ fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'rgba(244,228,193,0.35)', textDecoration: 'none' }}>
            Terms of Service
          </Link>
        </div>

        {/* Sign out */}
        <Button block size="large" icon={<LogoutOutlined />} onClick={handleSignOut}
          style={{ marginBottom: '1.5rem', borderRadius: 8, fontFamily: "'Lora', serif", letterSpacing: '0.1em', textTransform: 'uppercase', animation: 'fadeUp 0.55s ease 0.32s forwards', opacity: 0 }}>
          Sign Out
        </Button>

        {/* Danger zone */}
        <Card style={{ ...CARD_STYLE, borderColor: 'rgba(220,50,50,0.25)', background: 'rgba(40,8,8,0.75)', animationDelay: '0.46s', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}>
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
            <Input value={deleteConfirm} onChange={e => setDeleteConfirm(e.target.value)}
              placeholder={profileData?.username || user?.username || 'yourname'}
              style={{ maxWidth: 260, borderRadius: 8 }} />
          </div>
          <Button danger icon={<DeleteOutlined />} loading={deleteLoading} onClick={handleDelete}
            style={{ borderRadius: 8, fontFamily: "'Lora', serif" }}>
            Delete My Account
          </Button>
        </Card>
      </Content>
    </Layout>
  );
}
