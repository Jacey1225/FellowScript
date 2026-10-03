import React, { useCallback, useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Spin, Alert, Button, Input, Switch, Tag } from 'antd';
import {
  listHomeMessages, createHomeMessage, setHomeMessageEnabled, deleteHomeMessage,
} from '../lib/adminHomeMessagesApi.js';

// Local copies of the sibling admin card constants (AdminUserActions).
const CARD_STYLE = {
  background: 'rgba(92,68,42,0.34)',
  border: '1px solid rgba(255,225,170,0.16)',
  backdropFilter: 'blur(14px)',
  borderRadius: 22,
  marginBottom: '0.8rem',
  padding: '1rem 1.3rem',
};
const MUTED = { fontFamily: "'Inter', sans-serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.6)' };
const LABEL = { ...MUTED, display: 'block', marginBottom: '0.25rem' };
const DEFAULT_MAX_LEN = 120;

// Mirrors the server's plain-text rules (no angle brackets, no links). The
// server is the real enforcement; this only saves a round trip.
function clientProblem(text) {
  if (/[<>]/.test(text)) return 'Plain text only: no < or > characters.';
  if (/(https?:\/\/|www\.)/i.test(text)) return 'Links are not allowed in announcements.';
  return null;
}

// Home announcements card inside Account actions. Text is only ever rendered
// as a React text child (never as HTML).
export default function AdminHomeMessages() {
  const navigate = useNavigate();
  const [data, setData] = useState(null); // { items, text_max_length, max_enabled }
  const [loadError, setLoadError] = useState(null);
  const [error, setError] = useState(null);
  const [notice, setNotice] = useState(null);
  const [text, setText] = useState('');
  const [priority, setPriority] = useState('');
  const [creating, setCreating] = useState(false);
  const [busyId, setBusyId] = useState(null);
  const [pendingDelete, setPendingDelete] = useState(null);

  const handleAuthError = useCallback((err) => {
    if (err.status === 401) { navigate('/signin', { replace: true }); return true; }
    if (err.status === 403) { navigate('/', { replace: true }); return true; }
    return false;
  }, [navigate]);

  const load = useCallback(async () => {
    setLoadError(null);
    try {
      setData(await listHomeMessages());
    } catch (err) {
      if (!handleAuthError(err)) setLoadError("Couldn't load announcements.");
    }
  }, [handleAuthError]);

  useEffect(() => { load(); }, [load]);

  const items = data?.items || [];
  const maxLen = data?.text_max_length || DEFAULT_MAX_LEN;
  const maxEnabled = data?.max_enabled;
  const enabledCount = items.filter((m) => m.enabled).length;
  const atCap = typeof maxEnabled === 'number' && enabledCount >= maxEnabled;

  const act = async (id, fn, success) => {
    setBusyId(id);
    setError(null);
    setNotice(null);
    try {
      await fn();
      setNotice(success);
      await load();
    } catch (err) {
      if (!handleAuthError(err)) setError(err.message || 'Something went wrong.');
    } finally {
      setBusyId(null);
      setPendingDelete(null);
    }
  };

  const submit = async (e) => {
    e.preventDefault();
    const clean = text.trim();
    if (!clean) return;
    const problem = clientProblem(clean);
    if (problem) { setError(problem); setNotice(null); return; }
    const p = parseInt(priority, 10);
    setCreating(true);
    setError(null);
    setNotice(null);
    try {
      await createHomeMessage({ text: clean, priority: Number.isFinite(p) ? p : 0 });
      setText('');
      setPriority('');
      setNotice('Announcement added (off).');
      await load();
    } catch (err) {
      if (!handleAuthError(err)) setError(err.message || "Couldn't add the announcement.");
    } finally {
      setCreating(false);
    }
  };

  const toggle = (m, next) => act(m.id, () => setHomeMessageEnabled(m.id, next),
    next ? 'Announcement turned on.' : 'Announcement turned off.');

  return (
    <div style={CARD_STYLE}>
      <h2 style={{ margin: 0, fontSize: '1.05rem', color: '#f4e4c1' }}>Home announcements</h2>
      <p style={{ ...MUTED, margin: '0.15rem 0 0.8rem' }}>
        Shown as the headline on the app Home screen. If none are on, members see Welcome Back.
      </p>

      <form role="form" aria-label="Add home announcement" onSubmit={submit} style={{ marginBottom: '0.8rem' }}>
        <label htmlFor="home-msg-text" style={LABEL}>Announcement text</label>
        <Input.TextArea
          id="home-msg-text"
          rows={2}
          maxLength={maxLen}
          showCount
          value={text}
          onChange={(e) => setText(e.target.value)}
        />
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.8rem', alignItems: 'flex-end', marginTop: '0.6rem' }}>
          <div>
            <label htmlFor="home-msg-priority" style={LABEL}>Priority (higher shows first)</label>
            <Input
              id="home-msg-priority"
              type="number"
              inputMode="numeric"
              placeholder="0"
              value={priority}
              onChange={(e) => setPriority(e.target.value)}
              style={{ width: 140 }}
            />
          </div>
          <Button type="primary" htmlType="submit" loading={creating} disabled={!text.trim()}>
            Add announcement
          </Button>
        </div>
        <p style={{ ...MUTED, margin: '0.5rem 0 0' }}>Plain text only. New announcements start off.</p>
      </form>

      <div aria-live="polite">
        {notice && <Alert type="success" showIcon message={notice} style={{ borderRadius: 8, marginBottom: '0.8rem' }} />}
        {error && <Alert type="error" showIcon message={error} style={{ borderRadius: 8, marginBottom: '0.8rem' }} />}
      </div>

      {loadError ? (
        <Alert
          type="error"
          showIcon
          message="Couldn't load announcements."
          action={<Button type="link" size="small" onClick={load}>Retry</Button>}
          style={{ borderRadius: 8 }}
        />
      ) : data === null ? (
        <div style={{ minHeight: 80, display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Spin /></div>
      ) : (
        <>
          {typeof maxEnabled === 'number' && (
            <p style={{ ...MUTED, margin: '0 0 0.5rem' }}>
              {enabledCount} of {maxEnabled} on
              {atCap && ' · Turn one off to enable another.'}
            </p>
          )}
          {items.length === 0 ? (
            <p style={MUTED}>No announcements yet. Members see Welcome Back.</p>
          ) : (
            <ul style={{ listStyle: 'none', margin: 0, padding: 0 }} aria-label="Home announcements">
              {items.map((m) => {
                const busy = busyId === m.id;
                const confirming = pendingDelete === m.id;
                return (
                  <li key={m.id} data-testid={`home-msg-${m.id}`} style={{ borderTop: '1px solid rgba(255,225,170,0.12)', padding: '0.7rem 0' }}>
                    <p style={{ margin: 0, color: '#f4e4c1', fontFamily: "'Inter', sans-serif", fontSize: '0.9rem', overflowWrap: 'anywhere' }}>
                      {m.text}
                    </p>
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.6rem', alignItems: 'center', marginTop: '0.4rem' }}>
                      <Tag color={m.enabled ? 'gold' : 'default'} style={{ margin: 0 }}>{m.enabled ? 'On' : 'Off'}</Tag>
                      <span style={MUTED}>Priority {m.priority}</span>
                      <Switch
                        checked={!!m.enabled}
                        disabled={busy || (!m.enabled && atCap)}
                        loading={busy}
                        aria-label={`Show "${m.text.slice(0, 30)}" on Home`}
                        onChange={(next) => toggle(m, next)}
                      />
                      {confirming ? (
                        <>
                          <span style={MUTED}>Delete this announcement?</span>
                          <Button danger type="primary" loading={busy}
                            onClick={() => act(m.id, () => deleteHomeMessage(m.id), 'Deleted.')}>
                            Confirm delete
                          </Button>
                          <Button disabled={busy} onClick={() => setPendingDelete(null)}>Cancel</Button>
                        </>
                      ) : (
                        <Button danger disabled={busy} onClick={() => { setNotice(null); setPendingDelete(m.id); }}>
                          Delete
                        </Button>
                      )}
                    </div>
                  </li>
                );
              })}
            </ul>
          )}
        </>
      )}
    </div>
  );
}
