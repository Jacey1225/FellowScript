import React, { useState } from 'react';
import { Modal, Button, Spin } from 'antd';
import { CheckOutlined } from '@ant-design/icons';

// Task 20261003-web-reader-ios-parity (step 3). Web port of iOS
// AddGroupMembersSheet: pick friends who are not yet in the group and add them
// through the existing group update endpoint (any member may add; the server
// answers 409 for a full group or a listed group the caller does not own, and
// that message is shown as is). Stays open and shows the error on failure.
export default function AddGroupMembersModal({ open, onClose, candidates, onAdd }) {
  const [selected, setSelected] = useState([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const reset = () => { setSelected([]); setError(null); setBusy(false); };
  const close = () => { reset(); onClose(); };
  const toggle = (id) => setSelected(prev => (prev.includes(id) ? prev.filter(x => x !== id) : [...prev, id]));

  const submit = async () => {
    if (!selected.length || busy) return;
    setBusy(true); setError(null);
    const added = candidates.filter(c => selected.includes(c.id))
      .map(c => ({ user_id: c.id, username: c.name, photoUrl: c.photoUrl || null }));
    const res = await onAdd(added);
    if (res && res.ok) { close(); return; }
    setBusy(false);
    setError((res && res.detail) || "Couldn't add members. Please try again.");
  };

  return (
    <Modal
      open={open}
      onCancel={close}
      title="Add Members"
      centered
      destroyOnHidden
      width="min(420px, calc(100vw - 32px))"
      className="ring-modal"
      footer={[
        <Button key="cancel" onClick={close} disabled={busy}>Cancel</Button>,
        <Button key="add" type="primary" disabled={!selected.length || busy} onClick={submit}>
          {busy ? <Spin size="small" /> : (selected.length ? `Add (${selected.length})` : 'Add')}
        </Button>,
      ]}
    >
      {candidates.length === 0 ? (
        <p className="ring-empty">All your friends are already in this group.</p>
      ) : (
        <ul className="ring-list" aria-label="Friends to add">
          {candidates.map(c => {
            const on = selected.includes(c.id);
            return (
              <li key={c.id}>
                <button type="button" role="checkbox" aria-checked={on} aria-label={`${c.name}. ${on ? 'Selected' : 'Not selected'}`}
                  className="ring-row" onClick={() => toggle(c.id)}>
                  <span className="ring-row-avatar" aria-hidden="true">{(c.name || '?')[0].toUpperCase()}</span>
                  <span className="ring-row-text"><span className="ring-row-name">{c.name}</span></span>
                  <span className="ring-row-trailing">{on && <CheckOutlined style={{ color: 'var(--gold)' }} aria-hidden="true" />}</span>
                </button>
              </li>
            );
          })}
        </ul>
      )}
      {error && <p className="group-info-error" role="alert" style={{ marginTop: '0.6rem' }}>{error}</p>}
    </Modal>
  );
}
