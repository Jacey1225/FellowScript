// Task 20261012-share-verses-notes-in-chat (web/desktop). Recipient picker for
// "Send in chat": DMs and groups, a live preview of what will be sent. The server
// replaces message text on shared kinds, so there is no message field. Desktop uses the identical modal (same bundle).
import React, { useMemo, useState } from 'react';
import { Modal, Button, Spin } from 'antd';
import { CheckOutlined } from '@ant-design/icons';

export default function ShareToChatModal({ open, onClose, preview, friends, groups, loaded, onSend }) {
  const [selected, setSelected] = useState(null);
  const [busy, setBusy] = useState(false);

  const contacts = useMemo(() => {
    const dms = (friends || []).map((f) => ({ ...f }));
    const grps = Object.entries(groups || {}).map(([gid, g]) => ({
      id: gid, name: g.title || gid.slice(0, 8), type: 'group',
      toUsers: g.users || [], group_id: gid, photoUrl: g.photoUrl || null,
    }));
    return [...dms, ...grps];
  }, [friends, groups]);

  const close = () => { setSelected(null); setBusy(false); onClose(); };
  const submit = async () => {
    if (!selected || busy) return;
    setBusy(true);
    const contact = contacts.find((c) => `${c.type}:${c.id}` === selected);
    if (contact) await onSend(contact);
    setSelected(null); setBusy(false);
  };

  return (
    <Modal
      open={open}
      onCancel={close}
      title="Send in chat"
      centered
      destroyOnHidden
      width="min(440px, calc(100vw - 32px))"
      className="ring-modal"
      footer={[
        <Button key="cancel" onClick={close} disabled={busy}>Cancel</Button>,
        <Button key="send" type="primary" disabled={!selected || busy} onClick={submit}>
          {busy ? <Spin size="small" /> : 'Send'}
        </Button>,
      ]}
    >
      <div className="share-modal-preview" aria-label="Preview">{preview}</div>
      {!loaded ? (
        <div style={{ textAlign: 'center', padding: '0.8rem' }}><Spin size="small" /></div>
      ) : contacts.length === 0 ? (
        <p className="ring-empty">No chats yet</p>
      ) : (
        <ul className="ring-list share-modal-list" aria-label="Chats">
          {contacts.map((c) => {
            const key = `${c.type}:${c.id}`;
            const on = selected === key;
            return (
              <li key={key}>
                <button type="button" role="radio" aria-checked={on}
                  aria-label={`${c.name}, ${c.type === 'group' ? 'group' : 'friend'}. ${on ? 'Selected' : 'Not selected'}`}
                  className="ring-row" onClick={() => setSelected(key)}>
                  <span className="ring-row-avatar" aria-hidden="true">{(c.name || '?')[0].toUpperCase()}</span>
                  <span className="ring-row-text">
                    <span className="ring-row-name">{c.name}</span>
                  </span>
                  <span className="ring-row-trailing">{on && <CheckOutlined style={{ color: 'var(--gold)' }} aria-hidden="true" />}</span>
                </button>
              </li>
            );
          })}
        </ul>
      )}
    </Modal>
  );
}
