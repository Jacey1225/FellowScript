import React, { useState } from 'react';
import { Modal } from 'antd';
import { parseInviteInput } from '../lib/invitesApi.js';

// Task 20260929-group-invite-links (design-notes.md D): desktop paste-link
// flow. Accepts a full https://fellowscript.com/join/<token> URL or a bare
// token; anything else is rejected client-side. Navigates via the hash (not
// react-router) so this works wherever ContactsPanel is mounted; the
// destination is always the fixed same-origin route with the validated token.
export default function JoinWithLinkModal({ open, onClose }) {
  const [value, setValue] = useState('');
  const [error, setError] = useState(null);

  const close = () => { setValue(''); setError(null); onClose(); };
  const submit = () => {
    const token = parseInviteInput(value);
    if (!token) { setError("That doesn't look like a FellowScript invite link."); return; }
    setValue(''); setError(null);
    onClose();
    window.location.hash = `#/join/${token}`;
  };

  return (
    <Modal open={open} title="Join with a link" onOk={submit} onCancel={close} okText="Continue" destroyOnClose>
      <label htmlFor="join-link-input" className="group-info-helper" style={{ display: 'block', marginBottom: 6 }}>
        Paste an invite link
      </label>
      <input id="join-link-input" className="group-info-input" style={{ width: '100%' }} autoFocus
        value={value} onChange={(e) => { setValue(e.target.value); setError(null); }}
        onKeyDown={(e) => { if (e.key === 'Enter') submit(); }}
        aria-invalid={!!error} aria-describedby={error ? 'join-link-error' : undefined} />
      {error && <p id="join-link-error" className="group-info-error" role="alert" style={{ marginTop: 6 }}>{error}</p>}
    </Modal>
  );
}
