import React, { useState, useCallback } from 'react';
import { Modal, Button, Spin } from 'antd';
import { CheckOutlined, CheckCircleFilled, ClockCircleOutlined, WarningFilled } from '@ant-design/icons';
import { ringMembers, rowStateFromResult } from '../lib/ringApi.js';

// Task 20261003-web-reader-ios-parity (step 2). Web port of iOS
// RingMembersSheet: pick members of the session's group who have not joined,
// ring them, see a per-row outcome. Per-row states (independent):
//   default -> selected -> sending -> sent | rateLimited | error(caption)
// rateLimited / error rows are tap to retry (back to selected); sending / sent
// rows are not interactive. The modal stays open after ringing so the user
// sees each outcome. `sentRef` (a Set owned by the caller) keeps "sent" across
// reopenings during the same call.

const STATE_LABEL = { default: 'Not selected', selected: 'Selected', sending: 'Sending', sent: 'Sent', rateLimited: 'Rate limited' };

function stateLabel(st) { return st.kind === 'error' ? st.caption : STATE_LABEL[st.kind]; }
function caption(st) {
  if (st.kind === 'sent') return 'Sent';
  if (st.kind === 'rateLimited') return 'Rate limited';
  if (st.kind === 'error') return st.caption;
  return null;
}
const interactive = st => st.kind !== 'sending' && st.kind !== 'sent';

function Trailing({ st }) {
  if (st.kind === 'selected') return <CheckOutlined style={{ color: 'var(--gold)' }} aria-hidden="true" />;
  if (st.kind === 'sending') return <Spin size="small" aria-hidden="true" />;
  if (st.kind === 'sent') return <CheckCircleFilled style={{ color: 'rgba(120,200,120,0.85)' }} aria-hidden="true" />;
  if (st.kind === 'rateLimited') return <ClockCircleOutlined style={{ color: 'var(--gold)' }} aria-hidden="true" />;
  if (st.kind === 'error') return <WarningFilled style={{ color: '#e8877e' }} aria-hidden="true" />;
  return null;
}

export default function RingMembersModal({ open, onClose, session, user, candidates, sentRef }) {
  const [rows, setRows] = useState({});
  const [attempted, setAttempted] = useState(false);

  const stateOf = useCallback((id) => {
    if (rows[id]) return rows[id];
    return sentRef?.current?.has(id) ? { kind: 'sent' } : { kind: 'default' };
  }, [rows, sentRef]);

  const list = (candidates || []).filter(c => c && c.user_id && c.user_id !== user?.user_id);
  const joined = new Set(session?.participants || []);
  const notYet = list.filter(c => !joined.has(c.user_id));
  const already = list.filter(c => joined.has(c.user_id));
  const selectedIds = list.filter(c => stateOf(c.user_id).kind === 'selected').map(c => c.user_id);

  const toggle = (id) => {
    const cur = stateOf(id);
    if (!interactive(cur)) return;
    setRows(prev => ({ ...prev, [id]: cur.kind === 'selected' ? { kind: 'default' } : { kind: 'selected' } }));
  };

  const send = async () => {
    const targets = selectedIds;
    if (!targets.length || !user?.user_id || !session?.id) return;
    setAttempted(true);
    setRows(prev => { const n = { ...prev }; targets.forEach(id => { n[id] = { kind: 'sending' }; }); return n; });
    try {
      const results = await ringMembers(user.user_id, session.id, targets);
      setRows(prev => {
        const n = { ...prev };
        targets.forEach(id => {
          const st = rowStateFromResult(results[id]);
          n[id] = st;
          if (st.kind === 'sent') sentRef?.current?.add(id);
        });
        return n;
      });
    } catch (err) {
      const st = err && err.status === 429 ? { kind: 'rateLimited' } : { kind: 'error', caption: err?.message || "Couldn't send" };
      setRows(prev => { const n = { ...prev }; targets.forEach(id => { n[id] = st; }); return n; });
    }
  };

  const renderSection = (title, members, muted) => (
    <section className="ring-section" aria-label={title}>
      <h3 className="ring-section-title">{title}</h3>
      <ul className="ring-list">
        {members.map(m => {
          const st = stateOf(m.user_id);
          const cap = caption(st);
          const name = m.username || m.user_id.slice(0, 8);
          return (
            <li key={m.user_id}>
              <button
                type="button"
                role="checkbox"
                aria-checked={st.kind === 'selected' || st.kind === 'sent'}
                aria-disabled={!interactive(st)}
                aria-label={`${name}. ${stateLabel(st)}`}
                className={`ring-row${muted ? ' ring-row-muted' : ''}`}
                onClick={() => toggle(m.user_id)}
              >
                <span className="ring-row-avatar" aria-hidden="true">{name[0]?.toUpperCase()}</span>
                <span className="ring-row-text">
                  <span className="ring-row-name">{name}</span>
                  {cap && <span className={`ring-row-caption${st.kind === 'error' ? ' ring-row-caption-error' : ''}`}>{cap}</span>}
                </span>
                <span className="ring-row-trailing"><Trailing st={st} /></span>
              </button>
            </li>
          );
        })}
      </ul>
    </section>
  );

  return (
    <Modal
      open={open}
      onCancel={onClose}
      title="Ring Members"
      centered
      destroyOnHidden
      width="min(420px, calc(100vw - 32px))"
      className="ring-modal"
      footer={[
        <Button key="close" onClick={onClose}>{attempted ? 'Done' : 'Cancel'}</Button>,
        <Button key="ring" type="primary" disabled={selectedIds.length === 0} onClick={send}>
          {selectedIds.length ? `Ring (${selectedIds.length})` : 'Ring'}
        </Button>,
      ]}
    >
      {list.length === 0 && <p className="ring-empty">No other members to ring.</p>}
      {notYet.length > 0 && renderSection('Not yet joined', notYet, false)}
      {already.length > 0 && renderSection('Already in call', already, true)}
    </Modal>
  );
}
