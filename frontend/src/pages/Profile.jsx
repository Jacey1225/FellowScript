import React, { useCallback, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { Button, Skeleton, Modal, message } from 'antd';
import { LeftOutlined } from '@ant-design/icons';
import AppNav from '../components/AppNav.jsx';
import AppBloom from '../components/AppBloom.jsx';
import Seo from '../components/Seo.jsx';
import { FormSkin, FORM_CARD_STYLE } from '../components/forms/index.js';
import { ReportUserModal } from '../components/ContactsPanel.jsx';
import ProfileHeader from '../components/profile/ProfileHeader.jsx';
import ProfileBio from '../components/profile/ProfileBio.jsx';
import BioEditor from '../components/profile/BioEditor.jsx';
import ProfileActions, { ProfileOverflow } from '../components/profile/ProfileActions.jsx';
import { useAuth } from '../context/AuthContext.jsx';
import { useProfile } from '../hooks/useProfile.js';
import { useDeferredAction } from '../hooks/useDeferredAction.js';
import {
  saveBio, sendFriendRequest, acceptFriendRequest, declineFriendRequest, DECLINE_FAILURE, unfriend,
  blockProfile, unblockProfile, reportProfile,
} from '../lib/profileApi.js';
import { evictCachedProfile } from '../lib/profileCache.js';

// Task 20261030-user-profiles (design-notes.md). /#/profile/:userId. Bio is
// visible to self and friends only (the server omits the key otherwise); a
// 404 is the same "isn't available" screen for missing/blocked/suspended.
const RATE_COPY = 'Slow down a little and try again in a moment.';
const GENERIC_ACTION_ERROR = "Couldn't send that right now. Please try again.";

export default function Profile() {
  const { userId } = useParams();
  const { user } = useAuth();
  const navigate = useNavigate();
  const { profile, state, refreshing, refreshFailed, reload, patch, drop } = useProfile(user?.user_id, userId);
  const [busy, setBusy] = useState(null);
  const [editing, setEditing] = useState(false);
  const [status, setStatus] = useState('');
  const [reportTarget, setReportTarget] = useState(null);
  const deferred = useDeferredAction(6000);

  const goBack = useCallback(() => {
    const canGoBack = typeof window !== 'undefined' && (window.history.state?.idx ?? 0) > 0;
    if (canGoBack) navigate(-1); else navigate('/reader');
  }, [navigate]);

  if (!user) return null;

  const failCopy = (err, key) => (err.status === 429 ? RATE_COPY : key === 'decline' ? DECLINE_FAILURE : GENERIC_ACTION_ERROR);

  const runAction = async (key, fn) => {
    if (busy) return;
    setBusy(key); setStatus('');
    try {
      await fn();
      await reload();
    } catch (err) {
      setStatus(failCopy(err, key));
    } finally {
      setBusy(null);
    }
  };

  const handleAdd = () => runAction('add', () => sendFriendRequest(userId));
  const handleAccept = () => runAction('accept', () => acceptFriendRequest(userId));
  const handleDecline = () => runAction('decline', () => declineFriendRequest(user.user_id, userId));

  const handleSaveBio = async (text) => {
    const res = await saveBio(user.user_id, text.trim() === '' ? null : text);
    patch((p) => ({ ...p, bio: res.bio ?? null }));
    setEditing(false);
    message.success('Bio saved');
  };

  const handleBlock = () => {
    Modal.confirm({
      title: `Block ${profile.username}?`,
      content: "They won't be able to contact you or add you as a friend, and you won't see each other's profiles. We'll be notified so we can review the situation.",
      okText: 'Block', okButtonProps: { danger: true },
      onOk: async () => {
        try {
          await blockProfile(user.user_id, userId);
        } catch (err) {
          message.error(err.status === 429 ? RATE_COPY : 'Could not block this user.');
          return;
        }
        evictCachedProfile(user.user_id, userId);
        const name = profile.username;
        goBack();
        const key = `blocked-${userId}`;
        message.open({
          key, duration: 6,
          content: (
            <span>
              {name} blocked.{' '}
              <Link to="/account">Manage</Link>{' '}
              <Button type="link" size="small" onClick={async () => {
                try { await unblockProfile(user.user_id, userId); message.success(`${name} unblocked.`, 3); } catch { message.error('Could not unblock.'); }
              }}>Unblock</Button>
            </span>
          ),
        });
      },
    });
  };

  const handleUnfriend = () => {
    const before = profile;
    const name = profile.username;
    // Bio hides the moment Unfriend is tapped (design); commit after the grace period.
    patch((p) => { const { bio, ...rest } = p; return { ...rest, relationship: { state: 'none' } }; });
    const key = `unfriend-${userId}`;
    deferred.start(async () => {
      message.destroy(key);
      try {
        await unfriend(user.user_id, userId);
        evictCachedProfile(user.user_id, userId);
      } catch {
        message.error(`Couldn't remove ${name}. Please try again.`);
      }
      reload();
    });
    message.open({
      key, duration: 6,
      content: (
        <span>
          Removed {name}.{' '}
          <Button type="link" size="small" onClick={() => {
            if (deferred.undo()) { patch(() => before); message.destroy(key); }
          }}>Undo</Button>
        </span>
      ),
    });
  };

  const handleMessage = () => navigate('/reader', { state: { openDm: { id: userId, name: profile.username, photoUrl: profile.profile_photo_url || null } } });

  let body;
  let below = null;
  if (state === 'loading') {
    body = <Skeleton avatar={{ size: 96 }} active={!window.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches} paragraph={{ rows: 2 }} title />;
  } else if (state === 'unavailable') {
    body = (
      <div style={{ textAlign: 'center', padding: '2rem 0' }} role="status">
        <p style={{ fontSize: 17, color: 'var(--parchment)' }}>This profile isn't available.</p>
        <Button onClick={goBack} style={{ minHeight: 44 }}>Back</Button>
      </div>
    );
  } else if (state === 'error') {
    body = (
      <div style={{ textAlign: 'center', padding: '2rem 0' }} role="status">
        <p style={{ fontSize: 17, color: 'var(--parchment)' }}>Couldn't load this profile.</p>
        <Button onClick={reload} style={{ minHeight: 44 }}>Try again</Button>
      </div>
    );
  } else {
    body = (
      <>
        <div style={{ display: 'flex', justifyContent: 'flex-end', minHeight: 44 }}>
          <ProfileOverflow profile={profile} onReport={() => setReportTarget({ id: userId, name: profile.username })}
            onBlock={handleBlock} onUnfriend={handleUnfriend} />
        </div>
        <ProfileHeader profile={profile} />
        <div style={{ margin: '20px 0' }}>
          {editing
            ? <BioEditor initial={profile.bio || ''} onSave={handleSaveBio} onCancel={() => setEditing(false)} />
            : <ProfileBio profile={profile} onEdit={() => setEditing(true)} />}
        </div>
      </>
    );
    below = (
      <div style={{ marginTop: 12 }}>
        <ProfileActions profile={profile} busy={busy} editing={editing}
          onAdd={handleAdd} onAccept={handleAccept} onDecline={handleDecline} onMessage={handleMessage} onEdit={() => setEditing(true)} />
        <div role="status" aria-live="polite" style={{ marginTop: 12, minHeight: 20, fontSize: '0.85rem', color: 'var(--ff-text-2)' }}>
          {status || (refreshFailed
            ? <>Couldn't refresh. Showing what we had. <Button type="link" size="small" onClick={reload}>Retry</Button></>
            : refreshing ? 'Updating...' : '')}
        </div>
      </div>
    );
  }

  return (
    <>
      <Seo title="Profile — FellowScript" description="A FellowScript profile." path="/profile" noindex />
      <AppBloom variant="account" />
      <AppNav />
      <FormSkin>
        <div style={{ maxWidth: 480, margin: '0 auto', width: '100%', padding: '1.5rem 24px' }}>
          <button type="button" onClick={goBack} aria-label="Back"
            style={{ display: 'inline-flex', alignItems: 'center', gap: 6, marginBottom: '1rem', minHeight: 44, padding: 0, border: 'none', background: 'none', fontFamily: 'inherit', fontSize: '0.85rem', color: 'rgba(200,134,26,0.9)', cursor: 'pointer' }}>
            <LeftOutlined style={{ fontSize: '0.7rem' }} /> Back
          </button>
          <div style={{ ...FORM_CARD_STYLE, padding: '1.25rem' }}>{body}</div>
          {below}
        </div>
      </FormSkin>
      <ReportUserModal target={reportTarget}
        onSubmit={async (id, reason, detail) => { try { await reportProfile(id, reason, detail); return true; } catch { return false; } }}
        onClose={() => setReportTarget(null)} />
    </>
  );
}
