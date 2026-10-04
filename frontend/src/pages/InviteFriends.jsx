import React, { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Layout, Typography } from 'antd';
import AppBloom from '../components/AppBloom.jsx';
import AppNav from '../components/AppNav.jsx';
import Seo from '../components/Seo.jsx';
import FriendInviteCode from '../components/FriendInviteCode.jsx';
import RewardNotice from '../components/RewardNotice.jsx';
import { useAuth } from '../context/AuthContext.jsx';
import { fetchRewardSummary } from '../lib/ownerRewardsApi.js';

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
const MUTED = { fontFamily: "'Inter', sans-serif", fontSize: '0.85rem', color: 'rgba(244,228,193,0.5)' };

// Task 20261001-promo-owner-rewards: /#/invite. A signed-in user generates (or
// retrieves) their personal subscription invite link/code. The code is created
// server-side in the shared promo table attached to the user's email. When
// owner rewards are on, also shows how many rewards the user has earned. The
// reward summary is best-effort: a 404 (flag off) or any failure just hides it.
export default function InviteFriends() {
  const { user } = useAuth();
  const navigate = useNavigate();
  const [rewards, setRewards] = useState(null);

  useEffect(() => {
    if (!user) navigate('/signin', { replace: true });
  }, [user, navigate]);

  useEffect(() => {
    if (!user) return undefined;
    let live = true;
    fetchRewardSummary(user.user_id).then((s) => { if (live) setRewards(s); }).catch(() => {});
    return () => { live = false; };
  }, [user]);

  if (!user) return null;

  return (
    <Layout style={{ minHeight: '100vh', background: 'transparent' }}>
      <Seo title="Invite a friend" path="/invite" noindex />
      <AppBloom variant="account" />
      <AppNav />
      <Content className="fs-account-pad" style={{ maxWidth: 640, margin: '0 auto', width: '100%' }}>
        <Text className="fs-eyebrow">Invite</Text>
        <Title level={2} style={{ fontFamily: "'Playfair Display', serif", color: 'var(--parchment)', marginTop: 0 }}>
          Invite a friend
        </Title>
        {rewards && <RewardNotice userId={user.user_id} summary={rewards} />}
        <div style={CARD_STYLE}>
          <FriendInviteCode userId={user.user_id} />
        </div>
        {rewards && (
          <div style={CARD_STYLE} data-testid="reward-summary">
            <Text className="fs-eyebrow">
              Your rewards
            </Text>
            <p style={{ ...MUTED, margin: '0.5rem 0 0', lineHeight: 1.6 }}>
              When a friend joins with your code, you earn {rewards.percent_off}% off your next month.
              You have {rewards.earned} earned, {rewards.claimed} used.
              {rewards.provider === 'apple' && rewards.earned > 0 && ' Claim it in the FellowScript iPhone app under Account.'}
              {rewards.provider === 'stripe' && ' Rewards apply to your next invoice automatically.'}
              {!rewards.provider && ' Rewards apply once you have an individual plan.'}
            </p>
            <p style={{ ...MUTED, margin: '0.5rem 0 0', fontSize: '0.75rem' }}>
              Friends new to paid plans who subscribe on iPhone can&apos;t use a code there; they can subscribe on the web.
            </p>
          </div>
        )}
      </Content>
    </Layout>
  );
}
