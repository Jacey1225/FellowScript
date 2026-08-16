import React, { useEffect, useState, useCallback } from 'react';
import { Button, Spin, Alert, Tag, Avatar, Popconfirm, InputNumber } from 'antd';
import {
  CrownOutlined, TeamOutlined, UserOutlined,
  CheckOutlined, CloseOutlined, DeleteOutlined,
} from '@ant-design/icons';
import { API } from '../config.js';

// Radius/fill kept in sync with Account.jsx's own CARD_STYLE (design-notes.md
// §3's --radius-lg treatment) so the subscription card reads as the same
// card shape as the Overview/Plan Usage/Danger Zone sections around it.
const CARD_STYLE = {
  background: 'rgba(26,20,15,0.85)',
  border: '1px solid rgba(200,134,26,0.16)',
  backdropFilter: 'blur(14px)',
  borderRadius: 20,
  marginBottom: '1.5rem',
  padding: '1.25rem 1.4rem',
};

const LABEL = {
  fontFamily: "'Inter', sans-serif", fontSize: '0.56rem', letterSpacing: '0.3em',
  textTransform: 'uppercase', color: 'rgba(200,134,26,0.5)', display: 'block',
};
const MUTED = { fontFamily: "'Inter', sans-serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.35)' };

// Server-authoritative price table (mirrors api/schemas/subscription.py GROUP_PRICE_CENTS).
const GROUP_PRICE_CENTS = { 1: 1000, 2: 1799, 3: 2699, 4: 3599, 5: 4499, 6: 5399, 7: 6299, 8: 7199 };
const MIN_MEMBERS = 1;
const MAX_MEMBERS = 8;

const statusColor = (s) => ({
  active: 'gold', trialing: 'blue', past_due: 'orange', canceled: 'red', inactive: 'default',
}[s] || 'default');

const money = (cents) => `$${Math.round((cents || 0) / 100)}`;

// Server timestamps look like "2026-08-15 19:42:23+00:00"; normalise for Date().
const fmtDate = (s) => {
  if (!s) return '';
  const d = new Date(s.replace(' ', 'T'));
  return isNaN(d.getTime()) ? '' : d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
};

// `onPlanChange` is invoked whenever the acting user's own plan changes (start,
// cancel, or leave) so the parent can refresh dependent UI — notably the free-tier
// usage/limits panel, which flips between capped and unlimited with the plan.
export default function SubscriptionCard({ userId, onPlanChange }) {
  const [loading,  setLoading]  = useState(true);
  const [plan,     setPlan]     = useState(null);   // the plan the user is on (host or member)
  const [members,  setMembers]  = useState([]);     // group members (host view)
  const [requests, setRequests] = useState([]);     // incoming join requests (host view)
  const [myReqs,   setMyReqs]   = useState([]);     // this user's outstanding requests
  const [joinable, setJoinable] = useState([]);     // friends' group plans with room
  const [busy,     setBusy]     = useState('');     // key of the in-flight action
  const [msg,      setMsg]      = useState(null);
  const [selectedCount, setSelectedCount] = useState(1);  // signup member-count picker
  const [editCount, setEditCount] = useState(null);        // host's in-progress seat-count edit

  const isHost = plan && plan.user_id === userId;

  const load = useCallback(async () => {
    setLoading(true);
    try {
      // Current plan (404 = not subscribed).
      const planRes = await fetch(`${API}/subscriptions/user/${userId}`);
      const thePlan = planRes.ok ? await planRes.json() : null;
      setPlan(thePlan);

      // Host of a group plan → members + pending requests.
      if (thePlan && thePlan.user_id === userId && thePlan.plan_type === 'group') {
        const [mRes, rRes] = await Promise.all([
          fetch(`${API}/subscriptions/${thePlan.id}/members`),
          fetch(`${API}/subscriptions/${thePlan.id}/requests`),
        ]);
        setMembers(mRes.ok ? await mRes.json() : []);
        setRequests(rRes.ok ? await rRes.json() : []);
      } else {
        setMembers([]); setRequests([]);
      }

      // This user's outstanding join requests.
      const myReqRes = await fetch(`${API}/subscriptions/user/${userId}/requests`);
      setMyReqs(myReqRes.ok ? await myReqRes.json() : []);

      // Discover friends' group plans that still have room to join.
      const frRes   = await fetch(`${API}/friends/${userId}`);
      const friends = frRes.ok ? await frRes.json() : [];
      const found   = [];
      await Promise.all(friends.map(async (f) => {
        try {
          const r = await fetch(`${API}/subscriptions/user/${f.user_id}`);
          if (!r.ok) return;
          const p = await r.json();
          if (p.plan_type === 'group' && p.user_id === f.user_id) {
            const mr = await fetch(`${API}/subscriptions/${p.id}/members`);
            const mc = mr.ok ? (await mr.json()).length : p.max_members;
            if (mc < p.max_members) found.push({ ...p, hostName: f.username, memberCount: mc });
          }
        } catch {}
      }));
      setJoinable(found);
    } catch {
      setMsg({ type: 'error', text: 'Could not load subscription.' });
    } finally {
      setLoading(false);
    }
  }, [userId]);

  useEffect(() => { load(); }, [load]);

  const flash = (type, text) => { setMsg({ type, text }); setTimeout(() => setMsg(null), 4000); };

  // Handle the redirect back from Stripe Checkout (?sub=success | ?sub=cancel).
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const sub = params.get('sub');
    if (!sub) return;
    // Strip the query but keep the hash route.
    window.history.replaceState({}, '', window.location.pathname + window.location.hash);
    if (sub === 'cancel') { flash('info', 'Checkout canceled — no charge was made.'); return; }
    if (sub === 'success') {
      setLoading(true);
      // The webhook creates the plan; it may lag a second or two — poll for it.
      let tries = 0;
      const poll = async () => {
        tries += 1;
        try {
          const r = await fetch(`${API}/subscriptions/user/${userId}`);
          if (r.ok) { await load(); onPlanChange?.(); flash('success', 'Subscription active — enjoy your free month!'); return; }
        } catch {}
        if (tries < 6) setTimeout(poll, 1500);
        else { await load(); flash('info', 'Almost there — refresh in a moment if your plan is not shown yet.'); }
      };
      poll();
    }
  }, [userId, load]);

  // ── Actions ─────────────────────────────────────────────────────────────────

  // Start a plan via Stripe Checkout: the backend creates a hosted session and
  // we redirect the browser to it. Card entry happens on Stripe's page.
  const startCheckout = async (memberCount) => {
    setBusy('start');
    try {
      const res  = await fetch(`${API}/subscriptions/checkout`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ user_id: userId, member_count: memberCount }),
      });
      const data = await res.json().catch(() => ({}));
      if (res.ok && data.url) { window.location.href = data.url; return; }
      flash('error', data.detail || 'Could not start checkout.');
    } catch { flash('error', 'Could not reach the server.'); }
    finally { setBusy(''); }
  };

  // Host changes how many people their plan covers; re-prices server-side.
  const updateSeats = async (memberCount) => {
    setBusy('seats');
    try {
      const res = await fetch(`${API}/subscriptions/${plan.id}`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ member_count: memberCount }),
      });
      if (res.ok) { setEditCount(null); await load(); flash('success', 'Plan updated.'); }
      else { const d = await res.json().catch(() => ({})); flash('error', d.detail || 'Could not update plan.'); }
    } catch { flash('error', 'Could not reach the server.'); }
    finally { setBusy(''); }
  };

  const cancelPlan = async () => {
    setBusy('cancel');
    try {
      await fetch(`${API}/subscriptions/${plan.id}`, { method: 'DELETE' });
      await load(); onPlanChange?.(); flash('success', 'Plan canceled.');
    } catch { flash('error', 'Could not cancel plan.'); }
    finally { setBusy(''); }
  };

  const leavePlan = async () => {
    setBusy('leave');
    try {
      await fetch(`${API}/subscriptions/${plan.id}/members/${userId}`, { method: 'DELETE' });
      await load(); onPlanChange?.(); flash('success', 'You left the plan.');
    } catch { flash('error', 'Could not leave plan.'); }
    finally { setBusy(''); }
  };

  const acceptRequest = async (uid) => {
    setBusy(`acc-${uid}`);
    try {
      const res = await fetch(`${API}/subscriptions/${plan.id}/requests/${uid}/accept`, { method: 'POST' });
      if (res.ok) { await load(); }
      else { const d = await res.json().catch(() => ({})); flash('error', d.detail || 'Could not accept.'); }
    } catch { flash('error', 'Could not reach the server.'); }
    finally { setBusy(''); }
  };

  const declineRequest = async (uid) => {
    setBusy(`dec-${uid}`);
    try {
      await fetch(`${API}/subscriptions/${plan.id}/requests/${uid}`, { method: 'DELETE' });
      setRequests(prev => prev.filter(r => r.user_id !== uid));
    } catch { flash('error', 'Could not decline.'); }
    finally { setBusy(''); }
  };

  const removeMember = async (uid) => {
    setBusy(`rem-${uid}`);
    try {
      const res = await fetch(`${API}/subscriptions/${plan.id}/members/${uid}`, { method: 'DELETE' });
      if (res.ok || res.status === 204) setMembers(prev => prev.filter(m => m.user_id !== uid));
      else { const d = await res.json().catch(() => ({})); flash('error', d.detail || 'Could not remove.'); }
    } catch { flash('error', 'Could not reach the server.'); }
    finally { setBusy(''); }
  };

  const requestJoin = async (subId) => {
    setBusy(`join-${subId}`);
    try {
      const res = await fetch(`${API}/subscriptions/${subId}/requests?from_user_id=${userId}`, { method: 'POST' });
      if (res.ok || res.status === 201) { await load(); flash('success', 'Request sent to the host.'); }
      else { const d = await res.json().catch(() => ({})); flash('error', d.detail || 'Could not send request.'); }
    } catch { flash('error', 'Could not reach the server.'); }
    finally { setBusy(''); }
  };

  const cancelRequest = async (subId) => {
    setBusy(`cxl-${subId}`);
    try {
      await fetch(`${API}/subscriptions/${subId}/requests/${userId}`, { method: 'DELETE' });
      setMyReqs(prev => prev.filter(r => r.subscription_id !== subId));
    } catch { flash('error', 'Could not cancel request.'); }
    finally { setBusy(''); }
  };

  // ── Render ──────────────────────────────────────────────────────────────────

  // No plan (404) and an explicit free-tier row both mean "on the free plan".
  // The server now reports free users as 404/no-plan, so treat null as free too
  // to keep the "Free Plan · Active" badge showing.
  const isFree = !plan || plan.plan_type === 'free';

  return (
    <div style={CARD_STYLE}>
      <span style={{ ...LABEL, marginBottom: '1rem' }}>Subscription</span>
      {msg && <Alert type={msg.type} message={msg.text} showIcon style={{ marginBottom: 14, borderRadius: 8 }} />}

      {loading ? (
        <div style={{ textAlign: 'center', padding: '1.5rem' }}><Spin /></div>
      ) : !plan || isFree ? (
        // ── Free plan (default for new accounts) ────────────────────────────
        <>
          {isFree && (
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: '1rem' }}>
              <div style={{ width: 42, height: 42, borderRadius: '50%', background: 'rgba(200,134,26,0.12)', border: '1px solid rgba(200,134,26,0.3)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--gold)', fontSize: '1.1rem' }}>
                <UserOutlined />
              </div>
              <div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <span style={{ fontFamily: "'DM Serif Display', serif", fontSize: '1.1rem', color: 'var(--parchment)' }}>Free Plan</span>
                  <Tag color="default">Active</Tag>
                </div>
                <span style={MUTED}>10 notes/week · 1 AI event · 3 notifications</span>
              </div>
            </div>
          )}
          <p style={{ ...MUTED, marginBottom: '1rem', lineHeight: 1.65 }}>
            Upgrade to unlock <span style={{ color: 'var(--gold)' }}>unlimited notes, AI check-ins,</span> and notifications.
            Choose how many people join your plan — up to 8.
          </p>
          <div style={{ border: '1px solid rgba(200,134,26,0.2)', borderRadius: 12, padding: '1.1rem', maxWidth: 320 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 6, color: 'var(--gold)' }}>
              <TeamOutlined />
              <span style={{ fontFamily: "'DM Serif Display', serif", fontSize: '1.05rem', color: 'var(--parchment)' }}>Group</span>
            </div>
            <div style={{ fontFamily: "'DM Serif Display', serif", fontSize: '1.7rem', color: 'var(--gold)', lineHeight: 1 }}>
              {money(GROUP_PRICE_CENTS[selectedCount])}<span style={{ fontSize: '0.8rem', color: 'rgba(244,228,193,0.4)' }}>/mo</span>
            </div>
            <div style={{ ...MUTED, margin: '0.5rem 0 0.3rem' }}>Members</div>
            <InputNumber
              min={MIN_MEMBERS} max={MAX_MEMBERS} value={selectedCount}
              onChange={(v) => setSelectedCount(v || 1)}
              style={{ width: '100%', marginBottom: '0.6rem' }}
            />
            <div style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.72rem', color: 'rgba(200,134,26,0.7)', marginBottom: '0.9rem' }}>
              Free for 1 month, then {money(GROUP_PRICE_CENTS[selectedCount])}/mo
            </div>
            <Button type="primary" block loading={busy === 'start'}
              onClick={() => startCheckout(selectedCount)}
              style={{ borderRadius: 8, fontFamily: "'Inter', sans-serif" }}>
              Start free trial
            </Button>
          </div>
        </>
      ) : (
        // ── Active plan ──────────────────────────────────────────────────────
        <>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: '0.4rem' }}>
            {/* Sparing idle motion on the active-plan badge only (design-notes.md
                §1a.3) — reuses Home's low-amplitude float via the shared
                .fs-idle-float utility; respects prefers-reduced-motion. */}
            <div className="fs-idle-float" style={{ width: 42, height: 42, borderRadius: '50%', background: 'rgba(200,134,26,0.12)', border: '1px solid rgba(200,134,26,0.3)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--gold)', fontSize: '1.1rem' }}>
              {isHost ? <CrownOutlined /> : <TeamOutlined />}
            </div>
            <div style={{ flex: 1 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <span style={{ fontFamily: "'DM Serif Display', serif", fontSize: '1.15rem', color: 'var(--parchment)' }}>
                  Group Plan
                </span>
                <Tag color={statusColor(plan.status)} style={{ textTransform: 'capitalize' }}>
                  {plan.is_trial ? 'Free trial' : plan.status}
                </Tag>
              </div>
              <span style={MUTED}>
                {money(plan.price_cents)}/mo · {isHost ? 'You are the host' : 'Member'}
                {plan.plan_type === 'group' && ` · up to ${plan.max_members} members`}
              </span>
            </div>
          </div>

          {/* Trial / billing status */}
          {isHost && (plan.next_billing_date || plan.is_trial) && (
            <div style={{ marginTop: '0.7rem', padding: '0.6rem 0.8rem', borderRadius: 8, background: 'rgba(200,134,26,0.07)', border: '1px solid rgba(200,134,26,0.15)' }}>
              <span style={{ fontFamily: "'Inter', sans-serif", fontSize: '0.78rem', color: 'rgba(244,228,193,0.7)' }}>
                {plan.is_trial ? (
                  <>🎁 Free trial · <span style={{ color: 'var(--gold)' }}>{plan.trial_days_remaining} day{plan.trial_days_remaining === 1 ? '' : 's'} left</span>. First billing {fmtDate(plan.next_billing_date)}.</>
                ) : (
                  <>Next billing {fmtDate(plan.next_billing_date)}.</>
                )}
                {(plan.card_brand || plan.card_last4) && (
                  <span style={{ color: 'rgba(244,228,193,0.4)', textTransform: 'capitalize' }}>
                    {' '}· {plan.card_brand} •••• {plan.card_last4}
                  </span>
                )}
              </span>
            </div>
          )}

          {/* Seat-count editor (host view) */}
          {isHost && plan.plan_type === 'group' && (
            <div style={{ marginTop: '1rem', display: 'flex', alignItems: 'center', gap: 8 }}>
              <span style={LABEL}>Plan size</span>
              {editCount === null ? (
                <Button size="small" type="text" onClick={() => setEditCount(plan.max_members)}
                  style={{ color: 'var(--gold)', fontFamily: "'Inter', sans-serif", fontSize: '0.78rem' }}>
                  Change ({plan.max_members} member{plan.max_members === 1 ? '' : 's'})
                </Button>
              ) : (
                <>
                  <InputNumber min={MIN_MEMBERS} max={MAX_MEMBERS} value={editCount}
                    onChange={(v) => setEditCount(v || 1)} size="small" style={{ width: 70 }} />
                  <span style={MUTED}>{money(GROUP_PRICE_CENTS[editCount])}/mo</span>
                  <Button size="small" type="primary" loading={busy === 'seats'}
                    onClick={() => updateSeats(editCount)} style={{ borderRadius: 6 }}>Save</Button>
                  <Button size="small" type="text" onClick={() => setEditCount(null)}
                    style={{ color: 'rgba(244,228,193,0.5)' }}>Cancel</Button>
                </>
              )}
            </div>
          )}

          {/* Group members (host view) */}
          {isHost && plan.plan_type === 'group' && (
            <div style={{ marginTop: '1rem' }}>
              <span style={{ ...LABEL, marginBottom: '0.6rem' }}>Members ({members.length}/{plan.max_members})</span>
              {members.map(m => (
                <div key={m.user_id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '0.5rem 0', borderBottom: '1px solid rgba(200,134,26,0.08)' }}>
                  <Avatar size="small" style={{ background: 'rgba(200,134,26,0.15)', color: 'var(--gold)' }}>
                    {(m.username || '?')[0].toUpperCase()}
                  </Avatar>
                  <span style={{ flex: 1, fontFamily: "'Inter', sans-serif", fontSize: '0.84rem', color: 'var(--parchment)' }}>
                    {m.username}{m.user_id === userId && <span style={{ color: 'rgba(244,228,193,0.35)' }}> (you)</span>}
                  </span>
                  {m.user_id !== userId && (
                    <Button size="small" type="text" danger icon={<DeleteOutlined />} loading={busy === `rem-${m.user_id}`}
                      onClick={() => removeMember(m.user_id)} title="Remove member" />
                  )}
                </div>
              ))}
            </div>
          )}

          {/* Pending join requests (host view) */}
          {isHost && plan.plan_type === 'group' && requests.length > 0 && (
            <div style={{ marginTop: '1rem' }}>
              <span style={{ ...LABEL, marginBottom: '0.6rem' }}>Join Requests</span>
              {requests.map(r => (
                <div key={r.user_id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '0.5rem 0', borderBottom: '1px solid rgba(200,134,26,0.08)' }}>
                  <Avatar size="small" style={{ background: 'rgba(200,134,26,0.15)', color: 'var(--gold)' }}>
                    {(r.username || '?')[0].toUpperCase()}
                  </Avatar>
                  <span style={{ flex: 1, fontFamily: "'Inter', sans-serif", fontSize: '0.84rem', color: 'var(--parchment)' }}>{r.username}</span>
                  <Button size="small" type="primary" icon={<CheckOutlined />} loading={busy === `acc-${r.user_id}`}
                    onClick={() => acceptRequest(r.user_id)} style={{ borderRadius: 8 }}>Accept</Button>
                  <Button size="small" type="text" icon={<CloseOutlined />} loading={busy === `dec-${r.user_id}`}
                    onClick={() => declineRequest(r.user_id)} style={{ color: 'rgba(244,228,193,0.5)' }} />
                </div>
              ))}
            </div>
          )}

          {/* Manage plan */}
          <div style={{ marginTop: '1.1rem' }}>
            {isHost ? (
              <Popconfirm title="Cancel this plan?" description="This ends the plan and removes all members." okText="Cancel plan" cancelText="Keep"
                onConfirm={cancelPlan} okButtonProps={{ danger: true }}>
                <Button danger loading={busy === 'cancel'} icon={<DeleteOutlined />} style={{ borderRadius: 8, fontFamily: "'Inter', sans-serif" }}>
                  Cancel Plan
                </Button>
              </Popconfirm>
            ) : (
              <Button danger loading={busy === 'leave'} onClick={leavePlan} style={{ borderRadius: 8, fontFamily: "'Inter', sans-serif" }}>
                Leave Plan
              </Button>
            )}
          </div>
        </>
      )}

      {/* Outstanding requests this user sent */}
      {!loading && myReqs.length > 0 && (
        <div style={{ marginTop: '1.2rem', paddingTop: '1rem', borderTop: '1px solid rgba(200,134,26,0.1)' }}>
          <span style={{ ...LABEL, marginBottom: '0.6rem' }}>Your Pending Requests</span>
          {myReqs.map(r => (
            <div key={r.subscription_id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '0.4rem 0' }}>
              <span style={{ flex: 1, fontFamily: "'Inter', sans-serif", fontSize: '0.82rem', color: 'rgba(244,228,193,0.65)' }}>
                Requested to join a group plan
              </span>
              <Button size="small" type="text" loading={busy === `cxl-${r.subscription_id}`}
                onClick={() => cancelRequest(r.subscription_id)} style={{ color: 'rgba(244,228,193,0.5)' }}>Cancel</Button>
            </div>
          ))}
        </div>
      )}

      {/* Joinable friend group plans (only when not already on a plan) */}
      {!loading && !plan && joinable.length > 0 && (
        <div style={{ marginTop: '1.2rem', paddingTop: '1rem', borderTop: '1px solid rgba(200,134,26,0.1)' }}>
          <span style={{ ...LABEL, marginBottom: '0.6rem' }}>Join a Friend's Group Plan</span>
          {joinable.map(p => {
            const pending = myReqs.some(r => r.subscription_id === p.id);
            return (
              <div key={p.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '0.5rem 0', borderBottom: '1px solid rgba(200,134,26,0.08)' }}>
                <Avatar size="small" style={{ background: 'rgba(200,134,26,0.15)', color: 'var(--gold)' }}>
                  {(p.hostName || '?')[0].toUpperCase()}
                </Avatar>
                <span style={{ flex: 1, fontFamily: "'Inter', sans-serif", fontSize: '0.84rem', color: 'var(--parchment)' }}>
                  {p.hostName}'s Group
                  <span style={{ color: 'rgba(244,228,193,0.35)' }}> · {p.memberCount}/{p.max_members}</span>
                </span>
                <Button size="small" type="primary" disabled={pending} loading={busy === `join-${p.id}`}
                  onClick={() => requestJoin(p.id)} style={{ borderRadius: 8 }}>
                  {pending ? 'Requested' : 'Request'}
                </Button>
              </div>
            );
          })}
        </div>
      )}

    </div>
  );
}
