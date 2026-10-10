import React, { useEffect, useState, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import { Typography, Spin, Alert, Button, Input, InputNumber, Tag, Select, Popconfirm, Modal } from 'antd';
import { AdminPageHeader } from '../components/AdminShell.jsx';
import { useAuth } from '../context/AuthContext.jsx';
import {
  createCreatorCode, listCodesOverview, deactivateCode,
  reactivateCode, deleteCode, updateCodeEmail, updateCreator,
} from '../lib/ownerRewardsApi.js';
import { codesToCsv, csvFilename, downloadCsv } from '../lib/promoCsv.js';
import { isMfaRequiredError } from '../lib/adminMfa.js';
import { useAdminMfaRequired } from '../hooks/useAdminMfaRequired.js';

const { Text } = Typography;

const CARD_STYLE = {
  background: 'rgba(32,24,16,0.62)',
  border: '1px solid rgba(200,134,26,0.22)',
  backdropFilter: 'blur(14px)',
  borderRadius: 22,
  marginBottom: '1.25rem',
  padding: '1.25rem 1.4rem',
};
const LABEL = {
  fontFamily: "'Inter', sans-serif", fontWeight: 600, fontSize: '0.62rem', letterSpacing: '0.22em',
  textTransform: 'uppercase', color: 'rgba(224,170,60,0.78)', display: 'block', marginBottom: 4,
};
const MUTED = { fontFamily: "'Inter', sans-serif", fontSize: '0.8rem', color: 'rgba(244,228,193,0.5)' };
const SR_ONLY = {
  position: 'absolute', width: 1, height: 1, padding: 0, margin: -1, overflow: 'hidden',
  clip: 'rect(0,0,0,0)', whiteSpace: 'nowrap', border: 0,
};
const NEEDS_EMAIL_HINT = 'Add an owner email before this code can be activated.';
const NAME_MAX = 120;
const NOTES_MAX = 2000;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// Task 20261001-promo-owner-rewards: admin page (/#/admin/promo) to create secure
// creator codes bound to an owner email, deactivate/reactivate/delete them, and see redemption and
// reward counts. Server-side `require_admin` is the real enforcement; this page
// only reads the answer. Hidden like /admin (not linked from user nav). A 404 means
// the feature flag is off: the page shows a neutral "not available" notice.
export default function AdminPromoCodes() {
  const { user } = useAuth();
  const navigate = useNavigate();
  const endSessionForMfa = useAdminMfaRequired();
  const [checked, setChecked] = useState(false);
  const [unavailable, setUnavailable] = useState(false);
  const [rows, setRows] = useState([]);
  const [kind, setKind] = useState('');
  const [error, setError] = useState(null);

  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [notes, setNotes] = useState('');
  const [maxRedemptions, setMaxRedemptions] = useState(null);
  const [creating, setCreating] = useState(false);
  const [formError, setFormError] = useState(null);
  const [created, setCreated] = useState(null); // { creator, code }
  const [busyId, setBusyId] = useState(null);
  const [addingId, setAddingId] = useState(null);   // row id whose inline Add email is open
  const [addEmail, setAddEmail] = useState('');
  const [addError, setAddError] = useState(null);
  const [editRow, setEditRow] = useState(null);     // row being edited (creator-kind)
  const [editName, setEditName] = useState('');
  const [editEmail, setEditEmail] = useState('');
  const [editNotes, setEditNotes] = useState('');
  const [editError, setEditError] = useState(null);
  const [editSaving, setEditSaving] = useState(false);
  const [exportKind, setExportKind] = useState('');
  const [exporting, setExporting] = useState(false);

  // 401 -> sign in, 403 -> home, 404 -> feature off. Returns true if handled.
  const handleAuthError = useCallback((err) => {
    if (isMfaRequiredError(err)) { endSessionForMfa(); return true; }
    if (err.status === 401) { navigate('/signin', { replace: true }); return true; }
    if (err.status === 403) { navigate('/', { replace: true }); return true; }
    if (err.status === 404) { setUnavailable(true); return true; }
    return false;
  }, [navigate, endSessionForMfa]);

  const load = useCallback(async () => {
    if (!user) return;
    setError(null);
    try {
      setRows(await listCodesOverview({ kind: kind || undefined }));
    } catch (err) {
      if (!handleAuthError(err)) setError(err.message || "Couldn't load codes.");
    } finally {
      setChecked(true);
    }
  }, [user, kind, handleAuthError]);

  useEffect(() => { load(); }, [load]);

  const submit = async (e) => {
    e.preventDefault();
    setFormError(null);
    if (!name.trim()) { setFormError('Enter a creator name.'); return; }
    if (email.trim() && !EMAIL_RE.test(email.trim())) { setFormError('Enter a valid owner email.'); return; }
    setCreating(true);
    try {
      const out = await createCreatorCode({
        name: name.trim(), notes: notes.trim(), ownerEmail: email.trim(),
        maxRedemptions: maxRedemptions || undefined,
      });
      setCreated(out);
      setName(''); setEmail(''); setNotes(''); setMaxRedemptions(null);
      await load();
    } catch (err) {
      if (!handleAuthError(err)) setFormError(err.message || "Couldn't create the code.");
    } finally {
      setCreating(false);
    }
  };

  const runAction = async (row, fn, failMsg) => {
    setBusyId(row.id);
    setError(null);
    try {
      await fn(row.id);
      await load();
    } catch (err) {
      if (!handleAuthError(err)) setError(err.message || failMsg);
    } finally {
      setBusyId(null);
    }
  };
  const saveEmail = async (row) => {
    setAddError(null);
    const v = addEmail.trim();
    if (!EMAIL_RE.test(v)) { setAddError('Enter a valid email.'); return; }
    setBusyId(row.id);
    try {
      await updateCodeEmail(row.id, v);   // does not activate; admin presses Activate
      setAddingId(null); setAddEmail('');
      await load();
    } catch (err) {
      if (!handleAuthError(err)) setAddError(err.message || "Couldn't save the email.");
    } finally {
      setBusyId(null);
    }
  };
  const openEdit = (row) => {
    setEditRow(row);
    setEditName(row.creator_name || '');
    setEditEmail(row.owner_email || '');
    setEditNotes(row.creator_notes || '');
    setEditError(null);
  };
  const closeEdit = () => { if (!editSaving) setEditRow(null); };
  const removingEmail = !!(editRow?.owner_email) && !editEmail.trim();
  const saveEdit = async (e) => {
    e?.preventDefault();
    setEditError(null);
    const row = editRow;
    const n = editName.trim();
    const em = editEmail.trim();
    const nt = editNotes.trim();
    if (!n) { setEditError('Enter a creator name.'); return; }
    if (n.length > NAME_MAX) { setEditError(`Name must be ${NAME_MAX} characters or fewer.`); return; }
    if (nt.length > NOTES_MAX) { setEditError(`Notes must be ${NOTES_MAX} characters or fewer.`); return; }
    if (em && !EMAIL_RE.test(em)) { setEditError('Enter a valid owner email.'); return; }
    const creatorChanges = {};
    if (n !== (row.creator_name || '')) creatorChanges.name = n;
    if (nt !== (row.creator_notes || '')) creatorChanges.notes = nt;
    const emailChanged = em !== (row.owner_email || '');
    if (!Object.keys(creatorChanges).length && !emailChanged) { setEditRow(null); return; }
    setEditSaving(true);
    try {
      if (Object.keys(creatorChanges).length) await updateCreator(row.creator_id, creatorChanges);
      if (emailChanged) await updateCodeEmail(row.id, em);   // never activates; blank deactivates
      setEditRow(null);
      await load();
    } catch (err) {
      if (!handleAuthError(err)) {
        setEditError(err.message || "Couldn't save the changes.");
        load();   // a partial save (creator ok, email failed) should show on the list
      }
    } finally {
      setEditSaving(false);
    }
  };
  // Fetches every page (server caps a page at 500) for the chosen kind, then
  // downloads one CSV. Independent of the on-screen filter.
  const exportCsv = async () => {
    setExporting(true);
    setError(null);
    try {
      const PAGE = 500;
      const all = [];
      for (let offset = 0; ; offset += PAGE) {
        const page = await listCodesOverview({ kind: exportKind || undefined, limit: PAGE, offset });
        all.push(...page);
        if (page.length < PAGE) break;
      }
      downloadCsv(codesToCsv(all), csvFilename(exportKind));
    } catch (err) {
      if (!handleAuthError(err)) setError(err.message || "Couldn't export codes.");
    } finally {
      setExporting(false);
    }
  };
  const deactivate = (row) => runAction(row, deactivateCode, "Couldn't deactivate the code.");
  const reactivate = (row) => runAction(row, reactivateCode, "Couldn't reactivate the code.");
  const remove = (row) => runAction(row, deleteCode, "Couldn't delete the code.");

  if (!checked) {
    return (
      <div style={{ minHeight: '40vh', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <Spin size="large" />
      </div>
    );
  }

  return (
    <div>
        <AdminPageHeader title="Promo codes" />

        {unavailable ? (
          <Alert type="info" showIcon message="Owner rewards aren't enabled." style={{ borderRadius: 8 }} />
        ) : (
          <>
            <form onSubmit={submit} style={CARD_STYLE} aria-label="Create creator code">
              <Text style={LABEL}>New creator code</Text>
              <p style={{ ...MUTED, margin: '0 0 0.8rem' }}>
                Creates a creator and a secure random code attached to the owner email.
                Leave the email blank to save the creator as awaiting email: the code stays
                inactive until you add an email and activate it.
                When someone buys with the code, the owner earns a reward if they hold a plan.
              </p>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.9rem' }}>
                <div style={{ minWidth: 220, flex: 1 }}>
                  <label htmlFor="cc-name" style={LABEL}>Creator name</label>
                  <Input id="cc-name" value={name} maxLength={120} onChange={(e) => setName(e.target.value)} />
                </div>
                <div style={{ minWidth: 240, flex: 1 }}>
                  <label htmlFor="cc-email" style={LABEL}>Owner email (optional)</label>
                  <Input id="cc-email" type="email" value={email} maxLength={255} onChange={(e) => setEmail(e.target.value)} />
                </div>
                <div style={{ minWidth: 160 }}>
                  <label htmlFor="cc-max" style={LABEL}>Max redemptions</label>
                  <InputNumber id="cc-max" min={1} value={maxRedemptions} onChange={setMaxRedemptions} placeholder="No limit" style={{ width: '100%' }} />
                </div>
              </div>
              <div style={{ marginTop: '0.9rem' }}>
                <label htmlFor="cc-notes" style={LABEL}>Notes (optional)</label>
                <Input.TextArea id="cc-notes" rows={2} maxLength={2000} value={notes} onChange={(e) => setNotes(e.target.value)} />
              </div>
              <Button type="primary" htmlType="submit" loading={creating} style={{ marginTop: '0.9rem', borderRadius: 999 }}>
                Create code
              </Button>
              {formError && <Alert role="alert" type="error" showIcon message={formError} style={{ marginTop: '0.8rem', borderRadius: 8 }} />}
              {created?.code?.code && (
                <Alert
                  type="success" showIcon style={{ marginTop: '0.8rem', borderRadius: 8 }}
                  message={<span>Created code <strong data-testid="created-code" style={{ letterSpacing: '0.1em' }}>{created.code.code}</strong> for the owner.</span>}
                />
              )}
            </form>

            <div style={CARD_STYLE}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '0.8rem', gap: 12, flexWrap: 'wrap' }}>
                <Text style={{ ...LABEL, marginBottom: 0 }}>Codes</Text>
                <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                  <Select
                    aria-label="Filter by kind" value={kind} onChange={setKind} style={{ width: 160 }}
                    options={[{ value: '', label: 'All kinds' }, { value: 'creator', label: 'Creator' }, { value: 'friend', label: 'Friend' }]}
                  />
                  <Select
                    aria-label="Export kind" value={exportKind} onChange={setExportKind} style={{ width: 160 }}
                    options={[{ value: '', label: 'All codes' }, { value: 'creator', label: 'Creator codes' }, { value: 'friend', label: 'Friend codes' }]}
                  />
                  <Button shape="round" loading={exporting} onClick={exportCsv}>Download CSV</Button>
                </div>
              </div>
              {error && <Alert role="alert" type="error" showIcon message={error} style={{ marginBottom: '0.8rem', borderRadius: 8 }} />}
              {rows.length === 0 ? (
                <Text style={MUTED}>No codes yet.</Text>
              ) : (
                <div style={{ overflowX: 'auto' }}>
                  <table style={{ width: '100%', borderCollapse: 'collapse', ...MUTED }}>
                    <thead>
                      <tr style={{ textAlign: 'left' }}>
                        {['Code', 'Kind', 'Owner email', 'Redemptions', 'Rewards earned / claimed', 'Status', ''].map((h) => (
                          <th key={h} scope="col" style={{ ...LABEL, padding: '0 8px 8px 0' }}>{h}</th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {rows.map((r) => (
                        <tr key={r.id} data-testid="code-row" style={{ borderTop: '1px solid rgba(200,134,26,0.1)' }}>
                          <td style={{ padding: '8px 8px 8px 0', color: 'var(--parchment)', fontFamily: 'ui-monospace, Menlo, monospace' }}>
                            {r.code}{r.creator_name ? <div style={MUTED}>{r.creator_name}</div> : null}
                          </td>
                          <td style={{ padding: 8 }}>{r.kind}</td>
                          <td style={{ padding: 8 }}>
                            {r.owner_email || '—'}
                            {r.awaiting_email && (
                              <div style={{ marginTop: 4 }}>
                                <Tag color="orange">Needs email</Tag>
                                {addingId === r.id ? (
                                  <form
                                    onSubmit={(e) => { e.preventDefault(); saveEmail(r); }}
                                    aria-label={`Add email for ${r.code}`}
                                    style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginTop: 6 }}
                                  >
                                    <Input
                                      type="email" size="small" value={addEmail} maxLength={255} style={{ width: 200 }}
                                      aria-label={`Owner email for ${r.code}`} onChange={(e) => setAddEmail(e.target.value)}
                                    />
                                    <Button size="small" type="primary" shape="round" htmlType="submit" loading={busyId === r.id}>Save email</Button>
                                    <Button size="small" shape="round" onClick={() => { setAddingId(null); setAddEmail(''); setAddError(null); }}>Cancel</Button>
                                    {addError && <Alert role="alert" type="error" showIcon message={addError} style={{ width: '100%', borderRadius: 8 }} />}
                                  </form>
                                ) : (
                                  <Button size="small" type="link" onClick={() => { setAddingId(r.id); setAddEmail(''); setAddError(null); }} aria-label={`Add email for ${r.code}`}>
                                    Add email
                                  </Button>
                                )}
                              </div>
                            )}
                          </td>
                          <td style={{ padding: 8 }}>{r.redemption_count}{r.max_redemptions ? ` / ${r.max_redemptions}` : ''}</td>
                          <td style={{ padding: 8 }}>{r.rewards_earned} / {r.rewards_claimed}</td>
                          <td style={{ padding: 8 }}><Tag color={r.active ? 'gold' : 'default'}>{r.active ? 'Active' : 'Inactive'}</Tag></td>
                          <td style={{ padding: 8 }}>
                            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                              {r.active ? (
                                <Button size="small" danger shape="round" loading={busyId === r.id} onClick={() => deactivate(r)} aria-label={`Deactivate ${r.code}`}>
                                  Deactivate
                                </Button>
                              ) : r.awaiting_email ? (
                                <span
                                  tabIndex={0} title={NEEDS_EMAIL_HINT} aria-describedby={`needs-email-${r.id}`}
                                  style={{ display: 'inline-block' }}
                                >
                                  <Button size="small" shape="round" disabled aria-label={`Activate ${r.code}`} aria-describedby={`needs-email-${r.id}`}>
                                    Activate
                                  </Button>
                                  <span id={`needs-email-${r.id}`} style={SR_ONLY}>{NEEDS_EMAIL_HINT}</span>
                                </span>
                              ) : (
                                <Button size="small" shape="round" loading={busyId === r.id} onClick={() => reactivate(r)} aria-label={`Reactivate ${r.code}`}>
                                  Reactivate
                                </Button>
                              )}
                              {r.kind === 'creator' && r.creator_id && (
                                <Button size="small" shape="round" disabled={busyId === r.id} onClick={() => openEdit(r)} aria-label={`Edit ${r.code}`}>
                                  Edit
                                </Button>
                              )}
                              {r.kind === 'creator' && (
                                <Popconfirm
                                  title="Delete this code?"
                                  description="It can no longer be redeemed. Redemption history and earned rewards are kept. This can't be undone."
                                  okText="Delete" okButtonProps={{ danger: true }} cancelText="Cancel"
                                  onConfirm={() => remove(r)}
                                >
                                  <Button size="small" danger type="primary" shape="round" disabled={busyId === r.id} aria-label={`Delete ${r.code}`}>
                                    Delete
                                  </Button>
                                </Popconfirm>
                              )}
                            </div>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
            <Modal
              open={!!editRow} onCancel={closeEdit} title={editRow ? `Edit ${editRow.code}` : 'Edit'}
              footer={null} destroyOnClose maskClosable={!editSaving}
            >
              {editRow && (
                <form onSubmit={saveEdit} aria-label={`Edit creator code ${editRow.code}`}>
                  <p style={{ ...MUTED, margin: '0 0 0.8rem' }}>
                    Name and notes belong to the creator and apply to all of their codes.
                    The owner email belongs to this code only. The code itself, redemptions, and rewards do not change.
                  </p>
                  <label htmlFor="ec-name" style={LABEL}>Creator name</label>
                  <Input id="ec-name" value={editName} maxLength={NAME_MAX} onChange={(e) => setEditName(e.target.value)} />
                  <label htmlFor="ec-email" style={{ ...LABEL, marginTop: 12 }}>Owner email (this code only)</label>
                  <Input id="ec-email" type="email" value={editEmail} maxLength={255} onChange={(e) => setEditEmail(e.target.value)} />
                  {removingEmail && (
                    <Alert
                      type="warning" showIcon style={{ marginTop: 8, borderRadius: 8 }}
                      message="Removing the email deactivates this code until you add an email and activate it again."
                    />
                  )}
                  {!removingEmail && !editRow.owner_email && (
                    <p style={{ ...MUTED, margin: '6px 0 0' }}>Adding an email does not activate the code. Press Activate afterward.</p>
                  )}
                  <label htmlFor="ec-notes" style={{ ...LABEL, marginTop: 12 }}>Notes</label>
                  <Input.TextArea id="ec-notes" rows={3} maxLength={NOTES_MAX} value={editNotes} onChange={(e) => setEditNotes(e.target.value)} />
                  {editError && <Alert role="alert" type="error" showIcon message={editError} style={{ marginTop: '0.8rem', borderRadius: 8 }} />}
                  <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end', marginTop: '1rem' }}>
                    <Button shape="round" onClick={closeEdit} disabled={editSaving}>Cancel</Button>
                    <Button type="primary" shape="round" htmlType="submit" loading={editSaving}>Save changes</Button>
                  </div>
                </form>
              )}
            </Modal>
          </>
        )}
    </div>
  );
}
