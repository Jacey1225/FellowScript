import React, { useEffect, useState, useCallback, useRef } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import {
  Layout, Card, Form, Input, Button, Typography,
  Avatar, Spin, Alert, Divider, Row, Col,
  Switch, Modal, Checkbox, Select, TimePicker, Progress, message, Dropdown,
} from 'antd';
import {
  UserOutlined, MailOutlined, LockOutlined,
  LogoutOutlined, DeleteOutlined, RobotOutlined,
  PlusOutlined, ThunderboltOutlined, EditOutlined,
  CheckOutlined, CloseOutlined, CalendarOutlined, TeamOutlined,
  CameraOutlined, LeftOutlined,
} from '@ant-design/icons';
import dayjs from 'dayjs';
import utc from 'dayjs/plugin/utc';
import AppNav from '../components/AppNav.jsx';
import AppBloom from '../components/AppBloom.jsx';
import SubscriptionCard from '../components/SubscriptionCard.jsx';
import DonationButton from '../components/DonationButton.jsx';
import { useAuth } from '../context/AuthContext.jsx';
import { isDesktopApp } from '../lib/desktopScope.js';
import { API } from '../config.js';

dayjs.extend(utc);

const { Content } = Layout;
const { Title, Text, Paragraph } = Typography;

// Radius promoted to --radius-lg (20px, up from 14px) per design-notes.md
// §3 — this CARD_STYLE object is the live equivalent of the design doc's
// cited `.account-section` class (that selector only exists in the legacy
// static frontend/css/account.css, not this React app). The Danger Zone
// card below spreads this same object, so it stays a tinted variant of the
// same card shape rather than a separate one.
const CARD_STYLE = {
  background: 'rgba(26,20,15,0.85)',
  border: '1px solid rgba(200,134,26,0.16)',
  backdropFilter: 'blur(14px)',
  borderRadius: 20,
  marginBottom: '1.5rem',
};

// Full IANA timezone list where supported (most modern browsers); falls back
// to just the browser's own detected zone so the picker still works.
const timezoneOptions = (() => {
  try {
    return Intl.supportedValuesOf('timeZone').map(tz => ({ value: tz, label: tz }));
  } catch {
    const fallback = Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
    return [{ value: fallback, label: fallback }, { value: 'UTC', label: 'UTC' }];
  }
})();

// Task 20260905-profile-photo: mirrors ChatThread.jsx's ATTACHMENT_LIMITS.image
// verbatim (same allowlist as api/backend/interactions/attachments.py's
// PER_KIND_LIMITS["image"], which profile-photo uploads reuse wholesale) --
// advisory client-side pre-flight only, real enforcement is the presigned
// POST policy's content-length-range condition, S3-side.
const PHOTO_LIMITS = {
  maxBytes: 15 * 1024 * 1024,
  accept: ['image/jpeg', 'image/png', 'image/webp', 'image/heic'],
  oversizeCopy: 'Photos can be up to 15MB.',
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

// A single free-tier usage row: label, "used / limit", and a progress bar.
// When the plan is unlimited (subscribed), shows "Unlimited" instead of a meter.
function UsageMeter({ label, hint, data }) {
  const unlimited = !data || data.unlimited;
  const used  = data?.used  ?? 0;
  const limit = data?.limit ?? 0;
  const pct   = unlimited || !limit ? 0 : Math.min(100, Math.round((used / limit) * 100));
  const maxed = !unlimited && used >= limit;
  return (
    <div style={{ marginBottom: '1rem' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: '0.3rem' }}>
        <Text style={{ fontFamily: "'Lora', serif", color: 'rgba(244,228,193,0.85)', fontSize: '0.85rem' }}>
          {label}
          {hint && <span style={{ color: 'rgba(244,228,193,0.4)', fontSize: '0.7rem', marginLeft: 6 }}>{hint}</span>}
        </Text>
        <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.8rem', color: unlimited ? 'var(--gold)' : maxed ? '#e08b8b' : 'rgba(244,228,193,0.7)' }}>
          {unlimited ? 'Unlimited' : `${used} / ${limit}`}
        </Text>
      </div>
      {!unlimited && (
        <Progress
          percent={pct}
          showInfo={false}
          size="small"
          strokeColor={maxed ? '#c0392b' : 'var(--gold)'}
          trailColor="rgba(244,228,193,0.12)"
        />
      )}
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
  const [usage,          setUsage]          = useState(null);

  const [requests,        setRequests]        = useState([]);
  const [requestsLoading, setRequestsLoading] = useState({});

  // Profile photo (task 20260905-profile-photo)
  const [photoUploading,   setPhotoUploading]   = useState(false);
  const [photoError,       setPhotoError]       = useState(null);
  const [photoJustUpdated, setPhotoJustUpdated] = useState(false); // brief crossfade flag (Q18), not a persistent state
  const photoInputRef = useRef(null);

  const [deleteConfirm,  setDeleteConfirm]  = useState('');
  const [deleteLoading,  setDeleteLoading]  = useState(false);
  const [deleteMsg,      setDeleteMsg]      = useState(null);

  // Two-factor authentication (email code)
  const [mfaLoading,        setMfaLoading]        = useState(false);
  const [mfaMsg,            setMfaMsg]            = useState(null);
  const [mfaSetupModal,     setMfaSetupModal]     = useState(false);
  const [mfaCode,           setMfaCode]           = useState('');
  const [mfaConfirmLoading, setMfaConfirmLoading] = useState(false);
  const [mfaDisableModal,   setMfaDisableModal]   = useState(false);
  const [mfaDisablePass,    setMfaDisablePass]    = useState('');
  const [mfaDisableLoading, setMfaDisableLoading] = useState(false);

  // Blocked users
  const [blockedUsers,    setBlockedUsers]    = useState([]);
  const [blockedLoading,  setBlockedLoading]  = useState(false);
  const [unblockingId,    setUnblockingId]    = useState(null);

  // Agents
  const [agents,        setAgents]        = useState([]);
  const [agentsLoading, setAgentsLoading] = useState(false);
  const [agentModal,    setAgentModal]    = useState(false);
  const [newAgentRole,  setNewAgentRole]  = useState('');
  const [agentSaving,   setAgentSaving]   = useState(false);
  const [renamingId,    setRenamingId]    = useState(null);
  const [renameVal,     setRenameVal]     = useState('');

  // Events (heartbeats — flat list across all agents)
  const [events,        setEvents]        = useState([]);
  const [evModal,       setEvModal]       = useState(false);
  const [evStep,        setEvStep]        = useState(0); // 0=recurrence, 1=days, 2=details
  const [evRecur,       setEvRecur]       = useState('daily');
  const [evWeekdays,    setEvWeekdays]    = useState([]);
  const [evMonthDays,   setEvMonthDays]   = useState([]);
  const [evTime,        setEvTime]        = useState(dayjs());
  const [evAgentId,     setEvAgentId]     = useState('');
  const [evPrompt,      setEvPrompt]      = useState('');
  const [evGroupId,     setEvGroupId]     = useState(''); // '' = No Group / personal
  const [evSaving,      setEvSaving]      = useState(false);
  const [editingEvent,  setEditingEvent]  = useState(null); // FSHeartbeat being edited

  // The user's own groups (id + display title), for the event modal's gold
  // group-picker dropdown. profileData.groups only carries bare ids (see
  // loadProfile below), so this mirrors useNotes.js's existing loadGroups
  // pattern (GET /groups/{user_id}/{group_id} per id) rather than adding a
  // new group-listing endpoint.
  const [userGroups,    setUserGroups]    = useState([]);

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
      form.setFieldsValue({ username: data.username || '', email: data.email || '', timezone: data.timezone || 'UTC' });

      // Resolve display titles for the event modal's group picker (task
      // 20260902-group-tagged-devotions) — data.groups is bare ids only.
      const groupIds = data.groups || [];
      if (groupIds.length > 0) {
        const groupList = await Promise.all(groupIds.map(async gid => {
          try {
            const r = await fetch(`${API}/groups/${user.user_id}/${gid}`);
            if (r.ok) {
              const d = await r.json();
              return { id: gid, title: d.group?.title || gid.slice(0, 8) };
            }
          } catch (err) {
            console.error(`Failed to load group ${gid}:`, err);
          }
          return { id: gid, title: gid.slice(0, 8) };
        }));
        setUserGroups(groupList);
      } else {
        setUserGroups([]);
      }

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
          if (r.ok) {
            const d = await r.json();
            return { uid, username: d.username || uid.slice(0, 8), photoUrl: d.profile_photo_url || null };
          }
        } catch {}
        return { uid, username: uid.slice(0, 8), photoUrl: null };
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

  const loadUsage = useCallback(async () => {
    if (!user) return;
    try {
      const res = await fetch(`${API}/subscriptions/user/${user.user_id}/usage`);
      if (res.ok) setUsage(await res.json());
    } catch {}
  }, [user]);

  const loadBlockedUsers = useCallback(async () => {
    if (!user) return;
    setBlockedLoading(true);
    try {
      const res = await fetch(`${API}/blocks/${user.user_id}`);
      if (res.ok) {
        const list = await res.json();
        // BlockManager.list_blocked() (api/backend/interactions/blocks.py)
        // predates this task and wasn't extended with profile_photo_url --
        // resolved per-entry via the same already-photo-carrying GET /user
        // endpoint the friend-requests block above uses, rather than
        // leaving this one surface permanently initials-only.
        const withPhotos = await Promise.all(list.map(async u => {
          try {
            const r = await fetch(`${API}/user/${u.user_id}`);
            if (r.ok) { const d = await r.json(); return { ...u, profile_photo_url: d.profile_photo_url || null }; }
          } catch {}
          return { ...u, profile_photo_url: null };
        }));
        setBlockedUsers(withPhotos);
      }
    } catch {} finally { setBlockedLoading(false); }
  }, [user]);

  const handleUnblock = async (blockedId) => {
    setUnblockingId(blockedId);
    try {
      const res = await fetch(`${API}/blocks/${user.user_id}/${blockedId}`, { method: 'DELETE' });
      if (res.ok || res.status === 204) setBlockedUsers(prev => prev.filter(u => u.user_id !== blockedId));
    } finally {
      setUnblockingId(null);
    }
  };

  useEffect(() => { loadProfile(); loadAgents(); loadUsage(); loadBlockedUsers(); }, [loadProfile, loadAgents, loadUsage, loadBlockedUsers]);

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

  // Mirrors iOS NetworkService.updateAgent/renameAgent + AccountView's
  // toggleAgent/renameAgent: apply the optimistic UI change, then only
  // *keep* it once the write is confirmed to have succeeded server-side --
  // a rejected write must not be silently indistinguishable from a
  // successful one (Architecture Q27).
  const handleToggleAgent = async (agentId, enabled) => {
    const previous = agents.find(a => a.id === agentId)?.enabled;
    setAgents(prev => prev.map(a => a.id === agentId ? { ...a, enabled } : a));
    try {
      const res = await fetch(`${API}/agent/${user.user_id}/${agentId}`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ enabled }),
      });
      if (!res.ok) {
        setAgents(prev => prev.map(a => a.id === agentId && previous !== undefined ? { ...a, enabled: previous } : a));
        message.error('Could not update agent.');
      }
    } catch {
      setAgents(prev => prev.map(a => a.id === agentId && previous !== undefined ? { ...a, enabled: previous } : a));
      message.error('Could not update agent. Check your connection and try again.');
    }
  };

  const handleRenameAgent = async (agentId, name) => {
    const trimmed  = name.trim();
    const previous = agents.find(a => a.id === agentId)?.name;
    setAgents(prev => prev.map(a => a.id === agentId ? { ...a, name: trimmed } : a));
    setRenamingId(null);
    try {
      const res = await fetch(`${API}/agent/${user.user_id}/${agentId}`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: trimmed }),
      });
      if (!res.ok) {
        setAgents(prev => prev.map(a => a.id === agentId ? { ...a, name: previous ?? '' } : a));
        message.error('Could not rename agent.');
      }
    } catch {
      setAgents(prev => prev.map(a => a.id === agentId ? { ...a, name: previous ?? '' } : a));
      message.error('Could not rename agent. Check your connection and try again.');
    }
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
    setEditingEvent(null);
    setEvStep(0);
    setEvRecur('daily');
    setEvWeekdays([]);
    setEvMonthDays([]);
    setEvTime(dayjs());
    setEvAgentId(agents[0]?.id || '');
    setEvPrompt('');
    setEvGroupId('');
    setEvModal(true);
  };

  const openEditModal = (ev) => {
    setEditingEvent(ev);
    // Detect recurrence from timestamps
    const nonNull = (ev.timestamps || []).filter(Boolean);
    const count   = nonNull.length;
    let recur = count === 31 ? 'daily' : 'monthly';
    const filledDays = (ev.timestamps || [])
      .map((ts, i) => ts ? i + 1 : null)
      .filter(Boolean);

    setEvRecur(recur);
    setEvWeekdays([]);
    setEvMonthDays(recur === 'monthly' ? filledDays : []);
    // Parse stored UTC time and convert to local dayjs
    const timeStr = nonNull[0] || '09:00';
    const [h, m]  = timeStr.split(':').map(Number);
    setEvTime(dayjs.utc().hour(h).minute(m).local());
    setEvAgentId(ev.agent_id || agents[0]?.id || '');
    setEvPrompt(ev.prompt || '');
    setEvGroupId(ev.group_id || '');
    setEvStep(recur === 'daily' ? 2 : 1);
    setEvModal(true);
  };

  const handleSaveEvent = async () => {
    if (!evAgentId || !evPrompt.trim()) return;
    setEvSaving(true);
    try {
      const utcTime    = toUTCTime(evTime);
      const timestamps = buildTimestamps(evRecur, evWeekdays, evMonthDays, utcTime);
      // group_id: '' (rather than omitting the key) matches the server's own
      // `body.get("group_id") or None` falsy check in api/routes/agent.py.
      const body       = { timestamps, prompt: evPrompt.trim(), group_id: evGroupId || '' };

      if (editingEvent) {
        // Update existing heartbeat
        const res = await fetch(
          `${API}/agent/${user.user_id}/${editingEvent._id}/update_heartbeats`,
          { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ...body, agent_id: evAgentId }) }
        );
        if (res.ok) {
          setEvents(prev => prev.map(e =>
            e._id === editingEvent._id
              ? { ...e, timestamps, prompt: evPrompt.trim(), agent_id: evAgentId, group_id: evGroupId || null }
              : e
          ));
          setEvModal(false);
        }
      } else {
        // Create new heartbeat
        const res = await fetch(`${API}/agent/${user.user_id}/${evAgentId}/heartbeat`, {
          method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
        });
        if (res.status === 403) {
          const b = await res.json().catch(() => ({}));
          const { used, limit } = b.detail || {};
          message.warning(
            limit != null
              ? `Free plan limit reached (events: ${used}/${limit}). Upgrade for unlimited access.`
              : `You've reached your free plan limit for events. Upgrade for unlimited access.`
          );
        } else if (res.ok || res.status === 201) {
          setEvModal(false);
          await loadAgents();
          await loadUsage();
        }
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
    if (vals.timezone && vals.timezone !== (profileData?.timezone || 'UTC')) body.timezone = vals.timezone;

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

  // ── Profile photo (task 20260905-profile-photo) ────────────────────────────
  // Same three-step wire contract as ChatThread.jsx's message attachments
  // (request a presigned S3 POST policy over plain HTTP, upload the raw
  // bytes directly to S3 with it, then confirm) -- this server never
  // receives the photo bytes themselves.

  const handlePhotoChange = async (e) => {
    const file = e.target.files?.[0];
    e.target.value = '';
    if (!file) return;
    setPhotoError(null);
    if (file.size > PHOTO_LIMITS.maxBytes) { setPhotoError(PHOTO_LIMITS.oversizeCopy); return; }
    if (!PHOTO_LIMITS.accept.includes(file.type)) { setPhotoError("That file type isn't supported here."); return; }

    setPhotoUploading(true);
    try {
      const urlRes = await fetch(`${API}/user/${user.user_id}/photo/upload-url`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ content_type: file.type, size_bytes: file.size }),
      });
      if (!urlRes.ok) {
        const d = await urlRes.json().catch(() => ({}));
        setPhotoError(d.detail || "That file type isn't supported here.");
        return;
      }
      const { url, fields, object_key } = await urlRes.json();

      const form = new FormData();
      Object.entries(fields || {}).forEach(([k, v]) => form.append(k, v));
      form.append('file', file);
      const uploadRes = await fetch(url, { method: 'POST', body: form });
      if (!uploadRes.ok && uploadRes.status !== 204) {
        setPhotoError('Upload failed. Please try again.');
        return;
      }

      const confirmRes = await fetch(`${API}/user/${user.user_id}/photo/confirm`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ object_key }),
      });
      if (!confirmRes.ok) {
        setPhotoError('Could not save your new photo. Please try again.');
        return;
      }
      const { profile_photo_url } = await confirmRes.json();
      setProfileData(prev => ({ ...prev, profile_photo_url }));
      updateUser({ profile_photo_url });
      // Brief flag driving a CSS crossfade (Q18) as the photo replaces the
      // initials placeholder -- communicates the state change completing,
      // not decoration; the underlying class respects prefers-reduced-motion
      // (global.css's .fs-avatar-crossfade).
      setPhotoJustUpdated(true);
      setTimeout(() => setPhotoJustUpdated(false), 650);
    } catch {
      setPhotoError('Could not reach the server.');
    } finally {
      setPhotoUploading(false);
    }
  };

  const handleRemovePhoto = async () => {
    setPhotoError(null);
    setPhotoUploading(true);
    try {
      const res = await fetch(`${API}/user/${user.user_id}/photo`, { method: 'DELETE' });
      if (res.ok || res.status === 204) {
        setProfileData(prev => ({ ...prev, profile_photo_url: null }));
        updateUser({ profile_photo_url: null });
      } else {
        setPhotoError('Could not remove your photo. Please try again.');
      }
    } catch {
      setPhotoError('Could not reach the server.');
    } finally {
      setPhotoUploading(false);
    }
  };

  const handleMfaToggle = async (checked) => {
    setMfaMsg(null);
    if (!checked) { setMfaDisableModal(true); return; }
    setMfaLoading(true);
    try {
      const res = await fetch(`${API}/auth/mfa/enable`, { method: 'POST' });
      const data = await res.json();
      if (!res.ok) { setMfaMsg({ type: 'error', text: data.detail || 'Could not send confirmation code.' }); return; }
      setMfaSetupModal(true);
    } catch {
      setMfaMsg({ type: 'error', text: 'Could not reach the server.' });
    } finally {
      setMfaLoading(false);
    }
  };

  const handleMfaConfirm = async () => {
    setMfaConfirmLoading(true);
    try {
      const res = await fetch(`${API}/auth/mfa/confirm`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code: mfaCode }),
      });
      const data = await res.json();
      if (!res.ok) { setMfaMsg({ type: 'error', text: data.detail || 'Invalid or expired code.' }); return; }
      updateUser({ mfa_enabled: true });
      setProfileData(prev => ({ ...prev, mfa_enabled: true }));
      setMfaSetupModal(false);
      setMfaCode('');
      setMfaMsg({ type: 'success', text: 'Two-factor authentication is now on.' });
    } catch {
      setMfaMsg({ type: 'error', text: 'Could not reach the server.' });
    } finally {
      setMfaConfirmLoading(false);
    }
  };

  const handleMfaDisable = async () => {
    setMfaDisableLoading(true);
    try {
      const res = await fetch(`${API}/auth/mfa/disable`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ plain_pass: mfaDisablePass }),
      });
      const data = await res.json();
      if (!res.ok) { setMfaMsg({ type: 'error', text: data.detail || 'Incorrect password.' }); return; }
      updateUser({ mfa_enabled: false });
      setProfileData(prev => ({ ...prev, mfa_enabled: false }));
      setMfaDisableModal(false);
      setMfaDisablePass('');
      setMfaMsg({ type: 'success', text: 'Two-factor authentication is now off.' });
    } catch {
      setMfaMsg({ type: 'error', text: 'Could not reach the server.' });
    } finally {
      setMfaDisableLoading(false);
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

  // Page-level back navigation (task 20260906-account-back-navigation) --
  // distinct from the event-wizard "Back" buttons in evModalFooter above,
  // which step backward through the create/edit-event modal, not the page.
  //
  // `window.history.state.idx` is react-router's own in-app history cursor
  // (both createBrowserHistory and createHashHistory funnel through the
  // same getUrlBasedHistory, so this works identically for the web bundle
  // and the Tauri desktop webview, which loads that same HashRouter bundle
  // per desktop/PROGRESS.md). idx > 0 means this tab has a prior entry the
  // router itself pushed, so navigate(-1) lands back in-app rather than
  // off the app's history into an external referrer or a blank tab --
  // which is what a bare `navigate(-1)` risks when /account was the first
  // route loaded (direct link, bookmark, or a fresh desktop window).
  // Falls back to /reader, the app's own post-sign-in landing page
  // (SignIn.jsx), rather than guessing Home.
  const handleBack = () => {
    const canGoBack = typeof window !== 'undefined' && (window.history.state?.idx ?? 0) > 0;
    if (canGoBack) navigate(-1);
    else navigate('/reader');
  };

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
        {/* Gold dropdown-trigger + group submenu (task 20260902-group-tagged-devotions).
            Same filled-gold-pill visual recipe as the note editor's .note-editor-save
            button (global.css) -- gradient + dark ink text on a pill -- rather than
            a new button style. Selecting a group sets group_id on the heartbeat;
            when it fires, the note it generates inherits this group_id automatically. */}
        <div>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.7rem', letterSpacing: '0.2em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.55)', display: 'block', marginBottom: 6 }}>Group</Text>
          <Dropdown
            trigger={['click']}
            menu={{
              items: [
                { key: '', label: 'No Group' },
                ...userGroups.map(g => ({ key: g.id, label: g.title })),
              ],
              onClick: ({ key }) => setEvGroupId(key),
            }}
          >
            <button
              type="button"
              style={{
                display: 'inline-flex', alignItems: 'center', gap: 8,
                padding: '0.5rem 1.1rem', borderRadius: 999, border: 'none', cursor: 'pointer',
                background: 'linear-gradient(135deg, var(--gold-light), var(--gold) 60%, var(--gold-dim))',
                color: 'var(--ink)', fontFamily: "'Space Grotesk', sans-serif", fontWeight: 600, fontSize: '0.82rem',
              }}
            >
              <TeamOutlined />
              {evGroupId ? (userGroups.find(g => g.id === evGroupId)?.title || 'Group') : 'No Group'}
            </button>
          </Dropdown>
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
        onClick={handleSaveEvent}>{editingEvent ? 'Update' : 'Save'}</Button>,
    ];
  };

  // ── Render ─────────────────────────────────────────────────────────────────

  return (
    <Layout style={{ minHeight: '100vh', background: 'transparent' }}>
      <AppBloom variant="account" />
      <AppNav />

      <Content style={{ paddingTop: 'calc(var(--nav-h) + 2.5rem)', paddingBottom: '5rem', paddingLeft: '2rem', paddingRight: '2rem', maxWidth: 680, margin: '0 auto', width: '100%' }}>

        {/* Back navigation (task 20260906-account-back-navigation) -- a
            visible, clickable page-level control per the user's
            navigation-state-visibility preference (Q11.3), supplementing
            (not replacing) the persistent AppNav Home/Read/Account menu
            rendered above. Returns to wherever the user was before
            /account, falling back to /reader when there's no prior in-app
            page -- see handleBack. */}
        <button
          type="button"
          onClick={handleBack}
          aria-label="Back"
          style={{
            display: 'inline-flex', alignItems: 'center', gap: 6,
            marginBottom: '1.25rem', padding: 0, border: 'none', background: 'none',
            fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'rgba(200,134,26,0.7)',
            cursor: 'pointer', animation: 'fadeUp 0.55s ease forwards', opacity: 0,
          }}
        >
          <LeftOutlined style={{ fontSize: '0.65rem' }} /> Back
        </button>

        {/* Header */}
        <div style={{ marginBottom: '2rem', animation: 'fadeUp 0.55s ease forwards', opacity: 0, display: 'flex', alignItems: 'center', gap: '1.1rem' }}>
          <div style={{ position: 'relative', width: 76, height: 76, flexShrink: 0 }}>
            <Avatar
              size={76}
              src={data.profile_photo_url}
              className={photoJustUpdated ? 'fs-avatar-crossfade' : undefined}
              style={{
                background: 'rgba(200,134,26,0.12)',
                border: '1.5px solid var(--gold)',
                color: 'var(--gold)',
                fontFamily: "'Playfair Display', serif",
                fontSize: '1.7rem',
              }}
            >
              {(data.username || 'A')[0].toUpperCase()}
            </Avatar>
            <button
              type="button"
              onClick={() => photoInputRef.current?.click()}
              disabled={photoUploading}
              aria-label={data.profile_photo_url ? 'Change profile photo' : 'Add a profile photo'}
              style={{
                position: 'absolute', bottom: -2, right: -2, width: 28, height: 28, borderRadius: '50%',
                border: '1.5px solid var(--gold)', background: 'rgba(12,7,2,0.92)', color: 'var(--gold)',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                cursor: photoUploading ? 'default' : 'pointer', padding: 0,
              }}
            >
              {photoUploading ? <Spin size="small" /> : <CameraOutlined style={{ fontSize: '0.8rem' }} />}
            </button>
            <input
              ref={photoInputRef}
              type="file"
              accept={PHOTO_LIMITS.accept.join(',')}
              style={{ display: 'none' }}
              onChange={handlePhotoChange}
            />
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.6rem', letterSpacing: '0.32em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.55)', display: 'block', marginBottom: '0.2rem' }}>
              Your Profile
            </Text>
            <Title level={2} style={{ margin: 0, fontFamily: "'Playfair Display', serif", color: 'var(--parchment)' }}>
              {profileLoading ? 'Account' : <>{data.username || 'Account'}</>}
            </Title>
            {data.profile_photo_url && !photoUploading && (
              <Button type="link" size="small" onClick={handleRemovePhoto}
                style={{ padding: 0, height: 'auto', fontFamily: "'Lora', serif", fontSize: '0.72rem', color: 'rgba(244,228,193,0.4)' }}>
                Remove photo
              </Button>
            )}
          </div>
        </div>
        {photoError && (
          <Alert type="error" message={photoError} showIcon closable onClose={() => setPhotoError(null)}
            style={{ marginBottom: '1.2rem', borderRadius: 8 }} />
        )}

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

        {/* Subscription */}
        <div style={{ animationDelay: '0.12s', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}>
          <SubscriptionCard userId={user.user_id} onPlanChange={loadUsage} />
        </div>

        {/* Plan usage */}
        {usage && (
          <Card style={{ ...CARD_STYLE, animationDelay: '0.13s', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}>
            <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.56rem', letterSpacing: '0.3em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)', display: 'block', marginBottom: '1rem' }}>
              Plan Usage
            </Text>
            <UsageMeter label="Notes" hint={`last ${usage.window_days} days`} data={usage.resources?.notes} />
            <UsageMeter label="Agent events" data={usage.resources?.agent_events} />
            <UsageMeter label="Agent notifications" data={usage.resources?.agent_notifications} />
            {!usage.subscribed && (
              <Alert
                type="info"
                showIcon
                style={{ marginTop: '0.5rem', borderRadius: 8, background: 'rgba(200,134,26,0.08)', border: '1px solid rgba(200,134,26,0.25)' }}
                message="You're on the free plan. Upgrade to an Individual or Group plan for unlimited notes, events, and notifications."
              />
            )}
          </Card>
        )}

        {/* Donation */}
        <div style={{ animationDelay: '0.14s', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}>
          <DonationButton email={data.email || user.email} />
        </div>

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
            <Form.Item name="timezone" label="Timezone" extra="Sets when your nightly 3am data backup runs.">
              <Select
                showSearch
                placeholder="Select your timezone"
                options={timezoneOptions}
                filterOption={(input, option) => option.value.toLowerCase().includes(input.toLowerCase())}
              />
            </Form.Item>
            <Form.Item name="password" label="New Password" extra="Leave blank to keep current password.">
              <Input.Password prefix={<LockOutlined />} placeholder="New password…" />
            </Form.Item>
            <Button type="primary" htmlType="submit" loading={editLoading} style={{ borderRadius: 8, fontFamily: "'Lora', serif", letterSpacing: '0.08em' }}>
              Save Changes
            </Button>
          </Form>
        </Card>

        {/* Two-factor authentication */}
        <Card style={{ ...CARD_STYLE, animationDelay: '0.20s', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.56rem', letterSpacing: '0.3em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)', display: 'block', marginBottom: '1rem' }}>
            Two-Factor Authentication
          </Text>
          {mfaMsg && <Alert type={mfaMsg.type} message={mfaMsg.text} showIcon style={{ marginBottom: 16, borderRadius: 8 }} />}
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: '1rem' }}>
            <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.82rem', color: 'rgba(244,228,193,0.6)', maxWidth: 340 }}>
              When enabled, we'll email a 6-digit code to {profileData?.email || user.email} every time you sign in.
            </Text>
            <Switch checked={!!profileData?.mfa_enabled} loading={mfaLoading} onChange={handleMfaToggle} />
          </div>
        </Card>

        {/* Blocked users */}
        <Card style={{ ...CARD_STYLE, animationDelay: '0.22s', animation: 'fadeUp 0.55s ease forwards', opacity: 0 }}>
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.56rem', letterSpacing: '0.3em', textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)', display: 'block', marginBottom: '0.8rem' }}>
            Blocked Users
          </Text>
          {blockedLoading
            ? <Spin size="small" />
            : blockedUsers.length === 0
              ? <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.28)' }}>You haven't blocked anyone.</Text>
              : blockedUsers.map(({ user_id, username, profile_photo_url }) => (
                  <div key={user_id} style={{ display: 'flex', alignItems: 'center', gap: '0.75rem', padding: '0.6rem 0', borderBottom: '1px solid rgba(200,134,26,0.08)' }}>
                    <Avatar src={profile_photo_url} style={{ background: 'rgba(200,134,26,0.15)', border: '1px solid rgba(200,134,26,0.3)', color: 'var(--gold)', fontFamily: "'Playfair Display', serif" }}>
                      {username[0].toUpperCase()}
                    </Avatar>
                    <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.84rem', color: 'var(--parchment)', flex: 1 }}>{username}</Text>
                    <Button size="small" loading={unblockingId === user_id} onClick={() => handleUnblock(user_id)}
                      style={{ borderRadius: 8, fontFamily: "'Lora', serif" }}>
                      Unblock
                    </Button>
                  </div>
                ))
          }
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
              : requests.map(({ uid, username, photoUrl }) => (
                  <div key={uid} style={{ display: 'flex', alignItems: 'center', gap: '0.75rem', padding: '0.6rem 0', borderBottom: '1px solid rgba(200,134,26,0.08)' }}>
                    <Avatar src={photoUrl} style={{ background: 'rgba(200,134,26,0.15)', border: '1px solid rgba(200,134,26,0.3)', color: 'var(--gold)', fontFamily: "'Playfair Display', serif" }}>
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
                      <Button size="small" type="text" icon={<EditOutlined style={{ fontSize: '0.7rem' }} />}
                        onClick={() => openEditModal(ev)}
                        style={{ padding: '0 4px', color: 'rgba(200,134,26,0.6)', flexShrink: 0 }} />
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
          title={<Text style={{ fontFamily: "'Playfair Display', serif", color: 'var(--parchment)' }}>
            {editingEvent ? `Edit Event` : evModalTitle}
          </Text>}
          onCancel={() => setEvModal(false)}
          footer={evModalFooter()}
          destroyOnClose
        >
          {evModalContent()}
        </Modal>

        {/* Confirm enabling 2FA */}
        <Modal
          open={mfaSetupModal}
          title={<Text style={{ fontFamily: "'Playfair Display', serif", color: 'var(--parchment)' }}>Confirm two-factor authentication</Text>}
          onCancel={() => { setMfaSetupModal(false); setMfaCode(''); }}
          onOk={handleMfaConfirm}
          okText="Confirm"
          confirmLoading={mfaConfirmLoading}
        >
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'rgba(244,228,193,0.55)', display: 'block', marginBottom: '0.8rem' }}>
            Enter the 6-digit code we just emailed to {profileData?.email || user.email}.
          </Text>
          <Input
            placeholder="123456"
            value={mfaCode}
            onChange={e => setMfaCode(e.target.value)}
            onPressEnter={handleMfaConfirm}
            maxLength={6}
            style={{ fontSize: '1.1rem', letterSpacing: '0.3em', textAlign: 'center' }}
          />
        </Modal>

        {/* Confirm disabling 2FA */}
        <Modal
          open={mfaDisableModal}
          title={<Text style={{ fontFamily: "'Playfair Display', serif", color: 'var(--parchment)' }}>Turn off two-factor authentication</Text>}
          onCancel={() => { setMfaDisableModal(false); setMfaDisablePass(''); }}
          onOk={handleMfaDisable}
          okText="Turn Off"
          okButtonProps={{ danger: true }}
          confirmLoading={mfaDisableLoading}
        >
          <Text style={{ fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'rgba(244,228,193,0.55)', display: 'block', marginBottom: '0.8rem' }}>
            Enter your current password to confirm.
          </Text>
          <Input.Password
            prefix={<LockOutlined />}
            placeholder="Current password"
            value={mfaDisablePass}
            onChange={e => setMfaDisablePass(e.target.value)}
            onPressEnter={handleMfaDisable}
          />
        </Modal>

        {/* Legal links — /privacy and /terms aren't on the desktop
            allowlist (task 20260906-desktop-scope-lockdown), so this
            purely-navigational footer is hidden entirely in desktop mode
            rather than left as a dead-end in-app link. */}
        {!isDesktopApp() && (
          <div style={{ display: 'flex', justifyContent: 'center', gap: '2rem', marginBottom: '1.5rem' }}>
            <Link to="/privacy" style={{ fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'rgba(244,228,193,0.35)', textDecoration: 'none' }}>
              Privacy Policy
            </Link>
            <Link to="/terms" style={{ fontFamily: "'Lora', serif", fontSize: '0.78rem', color: 'rgba(244,228,193,0.35)', textDecoration: 'none' }}>
              Terms of Service
            </Link>
          </div>
        )}

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
