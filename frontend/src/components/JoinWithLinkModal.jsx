import React, { useState } from 'react';
import { ConfigProvider, Modal } from 'antd';
import { parseInviteInput } from '../lib/invitesApi.js';
import { Field } from './forms/index.js';
import { formTheme } from '../lib/formTokens.js';

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
    <ConfigProvider theme={formTheme}>
      <Modal open={open} title="Join with a link" onOk={submit} onCancel={close} okText="Continue" destroyOnClose>
        <div className="fs-form">
          <Field id="join-link-input" label="Paste an invite link" value={value} error={error} autoFocus
            autoComplete="off" autoCapitalize="none" spellCheck={false}
            onChange={(v) => { setValue(v); setError(null); }}
            onKeyDown={(e) => { if (e.key === 'Enter') submit(); }} />
        </div>
      </Modal>
    </ConfigProvider>
  );
}
