import React, { useCallback, useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Spin, Alert, Button, Input, Pagination } from 'antd';
import { AdminPageHeader } from '../components/AdminShell.jsx';
import { useAuth } from '../context/AuthContext.jsx';
import { fetchUsers, grantAdmin, revokeAdmin } from '../lib/adminUsersApi.js';
import { isMfaRequiredError } from '../lib/adminMfa.js';
import { useAdminMfaRequired } from '../hooks/useAdminMfaRequired.js';

const CARD_STYLE = {
  background: 'rgba(92,68,42,0.34)',
  border: '1px solid rgba(255,225,170,0.16)',
  backdropFilter: 'blur(14px)',
  borderRadius: 22,
  marginBottom: '0.8rem',
  padding: '1rem 1.3rem',
};
const MUTED = { fontFamily: "'Inter', sans-serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.6)' };

// Admin page (/#/admin/users): search users and grant/revoke the admin role.
// Server-side `require_admin` is the real enforcement; 401 -> sign in,
// 403 -> home. Own row can't be changed (server also refuses self-revoke).
export default function AdminUserActions() {
  const { user } = useAuth();
  const navigate = useNavigate();
  const endSessionForMfa = useAdminMfaRequired();
  const [input, setInput] = useState('');
  const [q, setQ] = useState('');
  const [page, setPage] = useState(1);
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);
  const [notice, setNotice] = useState(null);
  const [busyId, setBusyId] = useState(null);
  // pending confirmation: { id, make }
  const [pending, setPending] = useState(null);

  const handleAuthError = useCallback((err) => {
    if (isMfaRequiredError(err)) { endSessionForMfa(); return true; }
    if (err.status === 401) { navigate('/signin', { replace: true }); return true; }
    if (err.status === 403) { navigate('/', { replace: true }); return true; }
    return false;
  }, [navigate, endSessionForMfa]);

  const load = useCallback(async () => {
    if (!user) return;
    setError(null);
    try {
      setData(await fetchUsers({ q, page }));
    } catch (err) {
      if (!handleAuthError(err)) { setError(err.message || "Couldn't load users."); setData((d) => d || { users: [], total: 0, page, page_size: 25 }); }
    }
  }, [user, q, page, handleAuthError]);

  useEffect(() => { setPending(null); load(); }, [load]);

  const submitSearch = (e) => { e.preventDefault(); setNotice(null); setPage(1); setQ(input.trim()); };

  const confirm = async (u) => {
    const make = pending.make;
    setBusyId(u.id);
    setError(null);
    setNotice(null);
    try {
      const out = await (make ? grantAdmin(u.id) : revokeAdmin(u.id));
      setPending(null);
      setNotice(out.changed === false
        ? `${u.username} already ${make ? 'was' : 'was not'} an admin.`
        : `${u.username} is ${make ? 'now' : 'no longer'} an admin.`);
      await load();
    } catch (err) {
      if (!handleAuthError(err)) { setPending(null); setError(err.message || 'That action failed.'); }
    } finally {
      setBusyId(null);
    }
  };

  const users = data?.users || [];

  return (
    <div>
      <AdminPageHeader title="User actions" />
      <form onSubmit={submitSearch} role="search" style={{ display: 'flex', gap: '0.6rem', marginBottom: '1.1rem', flexWrap: 'wrap' }}>
        <Input
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Search by username or email"
          aria-label="Search users"
          maxLength={100}
          allowClear
          style={{ maxWidth: 340 }}
        />
        <Button type="primary" htmlType="submit">Search</Button>
      </form>
      <div aria-live="polite">
        {notice && <Alert type="success" showIcon message={notice} style={{ borderRadius: 8, marginBottom: '1rem' }} />}
        {error && <Alert type="error" showIcon message={error} style={{ borderRadius: 8, marginBottom: '1rem' }} />}
      </div>
      {data === null ? (
        <div style={{ minHeight: '30vh', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Spin size="large" /></div>
      ) : users.length === 0 ? (
        <p style={MUTED}>{q ? 'No users match that search.' : 'No users found.'}</p>
      ) : (
        <>
          <ul style={{ listStyle: 'none', margin: 0, padding: 0 }} aria-label="Users">
            {users.map((u) => {
              const self = !!user && u.id === user.user_id;
              const open = pending && pending.id === u.id ? pending : null;
              const busy = busyId === u.id;
              return (
                <li key={u.id} style={CARD_STYLE} data-testid={`user-${u.id}`}>
                  <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.6rem', alignItems: 'center', justifyContent: 'space-between' }}>
                    <div>
                      <h2 style={{ margin: 0, fontSize: '1.05rem', color: '#f4e4c1' }}>
                        {u.username}{self && ' (you)'}
                      </h2>
                      <p style={{ ...MUTED, margin: '0.15rem 0 0' }}>
                        {u.email || 'No email'} · {u.is_admin ? 'Admin' : 'Member'}
                      </p>
                    </div>
                    {open ? (
                      <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.6rem', alignItems: 'center' }}>
                        <span style={MUTED}>
                          {open.make ? `Make ${u.username} an admin?` : `Remove admin from ${u.username}?`}
                        </span>
                        <Button type="primary" danger={!open.make} loading={busy} onClick={() => confirm(u)}>
                          {open.make ? 'Confirm grant' : 'Confirm revoke'}
                        </Button>
                        <Button onClick={() => setPending(null)} disabled={busy}>Cancel</Button>
                      </div>
                    ) : (
                      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: '0.2rem' }}>
                        <Button
                          danger={u.is_admin}
                          disabled={self}
                          aria-describedby={self ? `self-${u.id}` : undefined}
                          onClick={() => { setNotice(null); setPending({ id: u.id, make: !u.is_admin }); }}
                        >
                          {u.is_admin ? 'Revoke admin' : 'Grant admin'}
                        </Button>
                        {self && <span id={`self-${u.id}`} style={MUTED}>You can't change your own role.</span>}
                      </div>
                    )}
                  </div>
                </li>
              );
            })}
          </ul>
          {data.total > data.page_size && (
            <Pagination
              current={data.page}
              pageSize={data.page_size}
              total={data.total}
              showSizeChanger={false}
              onChange={(p) => { setNotice(null); setPage(p); }}
              style={{ marginTop: '1rem' }}
            />
          )}
        </>
      )}
    </div>
  );
}
