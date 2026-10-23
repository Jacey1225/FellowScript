import React, { useCallback, useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Layout, Typography, Switch, Spin, Alert, Button } from 'antd';
import { LeftOutlined } from '@ant-design/icons';
import AppBloom from '../components/AppBloom.jsx';
import AppNav from '../components/AppNav.jsx';
import Seo from '../components/Seo.jsx';
import { useAuth } from '../context/AuthContext.jsx';
import { useCapabilities } from '../hooks/useCapabilities.js';
import { fetchPushPreferences, savePushPreference, visibleGroups } from '../lib/notificationPreferences.js';

const { Content } = Layout;
const { Title, Text } = Typography;

const CARD_STYLE = {
  background: 'rgba(32,24,16,0.62)',
  border: '1px solid rgba(200,134,26,0.22)',
  backdropFilter: 'blur(14px)',
  borderRadius: 22,
  padding: '1.25rem 1.4rem',
  marginBottom: '1.25rem',
};
const MUTED = { fontFamily: 'inherit', fontSize: '0.82rem', color: 'rgba(244,228,193,0.65)' };

// Task 20261012-notification-settings: /#/account/notifications. One switch per
// user-toggleable push type, showing only server-confirmed values. A change is
// saved immediately; on failure the switch stays at the confirmed value and an
// inline error is shown. Types behind a server flag are hidden while it is off.
export default function NotificationSettings() {
  const { user } = useAuth();
  const navigate = useNavigate();
  const caps = useCapabilities();
  const [prefs, setPrefs] = useState(null);
  const [loadError, setLoadError] = useState(false);
  const [savingKey, setSavingKey] = useState(null);
  const [saveError, setSaveError] = useState(null);

  useEffect(() => {
    if (!user) navigate('/signin', { replace: true });
  }, [user, navigate]);

  const load = useCallback(async () => {
    if (!user) return;
    setLoadError(false);
    try {
      setPrefs(await fetchPushPreferences(user.user_id));
    } catch {
      setLoadError(true);
    }
  }, [user]);

  useEffect(() => { load(); }, [load]);

  const onToggle = async (key, label, next) => {
    if (!user || savingKey) return;
    setSavingKey(key);
    setSaveError(null);
    try {
      setPrefs(await savePushPreference(user.user_id, key, next));
    } catch {
      setSaveError(`Couldn't save "${label}". Please try again.`);
    } finally {
      setSavingKey(null);
    }
  };

  if (!user) return null;
  const groups = visibleGroups(caps.isEnabled);

  return (
    <Layout style={{ minHeight: '100vh', background: 'transparent' }}>
      <Seo title="Notifications — FellowScript" path="/account/notifications" noindex />
      <AppBloom variant="account" />
      <AppNav />
      <Content className="fs-account-pad" style={{ maxWidth: 680, margin: '0 auto', width: '100%' }}>
        <button
          type="button"
          onClick={() => navigate('/account')}
          aria-label="Back to account"
          style={{
            display: 'inline-flex', alignItems: 'center', gap: 6,
            marginBottom: '1.25rem', padding: 0, border: 'none', background: 'none',
            fontFamily: 'inherit', fontSize: '0.85rem', color: 'rgba(200,134,26,0.85)',
            cursor: 'pointer',
          }}
        >
          <LeftOutlined aria-hidden="true" style={{ fontSize: '0.65rem' }} /> Account
        </button>

        <Text className="fs-eyebrow">Account</Text>
        <Title level={2} style={{ fontFamily: 'inherit', color: 'var(--parchment)', marginTop: 0 }}>
          Notifications
        </Title>
        <p style={{ ...MUTED, marginTop: 0, marginBottom: '1.25rem', lineHeight: 1.6 }}>
          These settings control the push notifications sent to your iPhone. Turn on notifications
          in the FellowScript iPhone app to receive them. Incoming call alerts and replies to your
          own join requests are always sent.
        </p>

        {saveError && (
          <Alert role="alert" type="error" showIcon message={saveError} closable
            onClose={() => setSaveError(null)} style={{ marginBottom: 16, borderRadius: 8 }} />
        )}

        {loadError && (
          <div style={CARD_STYLE}>
            <Alert role="alert" type="error" showIcon message="Couldn't load your notification settings."
              style={{ marginBottom: 12, borderRadius: 8 }} />
            <Button onClick={load}>Try again</Button>
          </div>
        )}

        {!loadError && !prefs && (
          <div style={{ ...CARD_STYLE, textAlign: 'center' }}><Spin aria-label="Loading notification settings" /></div>
        )}

        {prefs && groups.map((g) => (
          <section key={g.title} style={CARD_STYLE} aria-labelledby={`notif-group-${g.title}`}>
            <Text id={`notif-group-${g.title}`} className="fs-eyebrow" style={{ marginBottom: '0.8rem' }}>
              {g.title}
            </Text>
            {g.types.map((t) => {
              const descId = `notif-desc-${t.key}`;
              return (
                <div key={t.key} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: '1rem', padding: '0.6rem 0' }}>
                  <div style={{ minWidth: 0 }}>
                    <div style={{ fontFamily: 'inherit', fontSize: '0.95rem', color: 'var(--parchment)' }}>{t.label}</div>
                    <div id={descId} style={MUTED}>{t.description}</div>
                  </div>
                  <Switch
                    checked={prefs[t.key] === true}
                    loading={savingKey === t.key}
                    disabled={savingKey !== null}
                    aria-label={`${t.label} notifications`}
                    aria-describedby={descId}
                    onChange={(next) => onToggle(t.key, t.label, next)}
                  />
                </div>
              );
            })}
          </section>
        ))}
      </Content>
    </Layout>
  );
}
