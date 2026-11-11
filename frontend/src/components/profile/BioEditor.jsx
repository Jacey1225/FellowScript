import React, { useState } from 'react';
import { Button, Input } from 'antd';
import { CheckOutlined } from '@ant-design/icons';
import { bioCounter } from '../../lib/profileBio.js';
import { BIO_MAX_LENGTH } from '../../lib/profileApi.js';

// Task 20261030-user-profiles (design E1: inline edit). The draft is kept
// verbatim on a failed save; the error shows inline under the field and Save
// stays available. Over-limit paste is accepted and flagged, never cut.
const TONE_COLOR = { normal: 'var(--ff-text-2)', warn: 'var(--ff-gold)', over: 'var(--ff-error)' };

export default function BioEditor({ initial, onSave, onCancel }) {
  const [draft, setDraft] = useState(initial || '');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const counter = bioCounter(draft);
  // Announce only at thresholds (20 left, 0 left, over) to avoid chatter.
  const announce = counter.tone === 'normal' ? '' : counter.label;

  const save = async () => {
    if (saving || counter.over) return;
    setSaving(true); setError('');
    try {
      await onSave(draft);
    } catch (err) {
      setError(err.message || "Couldn't save your bio. Your text is still here.");
      setSaving(false);
    }
  };

  return (
    <div>
      <Input.TextArea
        autoFocus
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        autoSize={{ minRows: 3, maxRows: 8 }}
        aria-label="Bio"
        aria-describedby="profile-bio-help"
        status={counter.over ? 'error' : undefined}
        disabled={saving}
        onKeyDown={(e) => { if (e.key === 'Escape') onCancel(); }}
      />
      <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, marginTop: 6, fontSize: '0.78rem' }}>
        <span id="profile-bio-help" style={{ color: 'var(--ff-text-2)' }}>
          Plain text, up to {BIO_MAX_LENGTH} characters. No links.
        </span>
        <span style={{ color: TONE_COLOR[counter.tone], fontWeight: counter.tone === 'normal' ? 400 : 600, whiteSpace: 'nowrap' }}>
          {counter.label}
        </span>
      </div>
      <span aria-live="polite" style={{ position: 'absolute', width: 1, height: 1, overflow: 'hidden', clip: 'rect(0 0 0 0)' }}>{announce}</span>
      {error && <div role="alert" style={{ color: 'var(--ff-error)', fontSize: '0.82rem', marginTop: 8 }}>{error}</div>}
      <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
        <Button type="primary" icon={<CheckOutlined />} loading={saving} disabled={!!counter.over} onClick={save} style={{ minHeight: 44 }}>Save</Button>
        <Button type="text" disabled={saving} onClick={onCancel} style={{ minHeight: 44 }}>Cancel</Button>
      </div>
    </div>
  );
}
