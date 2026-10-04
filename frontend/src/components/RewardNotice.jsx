import React, { useEffect, useState } from 'react';
import { Button } from 'antd';
import { fetchRewardSummary } from '../lib/ownerRewardsApi.js';

// Web counterpart of the iOS "You earned 50% off your next month" notice.
// Shown only when the signed-in user has at least one earned reward. Pass
// `summary` when the parent already fetched GET /rewards/{user_id}; otherwise
// the notice fetches it itself. Any error or 404 (feature off) renders
// nothing. Display only: the server decides and applies every reward.
// Dismissal lasts for the browser session and re-shows if the earned count changes.
const BOX = {
  background: 'rgba(200,134,26,0.12)',
  border: '1px solid rgba(200,134,26,0.45)',
  borderRadius: 18,
  padding: '1rem 1.25rem',
  marginBottom: '1.25rem',
};
const TITLE = { fontFamily: "'Playfair Display', serif", fontSize: '1.15rem', color: 'var(--parchment)', margin: 0 };
const BODY = { fontFamily: "'Inter', sans-serif", fontSize: '0.85rem', lineHeight: 1.6, color: 'rgba(244,228,193,0.7)', margin: '0.4rem 0 0' };

const dismissKey = (userId, earned) => `fs-reward-notice-dismissed:${userId}:${earned}`;
function wasDismissed(userId, earned) {
  try { return sessionStorage.getItem(dismissKey(userId, earned)) === '1'; } catch { return false; }
}

export function rewardNoticeText(s) {
  if (s.provider === 'apple') {
    return 'Open the FellowScript iPhone app, go to Account, and tap Claim reward to apply it.';
  }
  if (s.provider === 'stripe') {
    return 'It applies to your next invoice automatically. You do not need to do anything.';
  }
  return 'It applies once you have an individual plan.';
}

export default function RewardNotice({ userId, summary }) {
  const [fetched, setFetched] = useState(null);
  const [hidden, setHidden] = useState(false);
  const given = summary !== undefined;

  useEffect(() => {
    if (given || !userId) return undefined;
    let live = true;
    fetchRewardSummary(userId).then((s) => { if (live) setFetched(s); }).catch(() => {});
    return () => { live = false; };
  }, [given, userId]);

  const s = given ? summary : fetched;
  if (!s || !(s.earned > 0) || hidden || wasDismissed(userId, s.earned)) return null;

  const dismiss = () => {
    try { sessionStorage.setItem(dismissKey(userId, s.earned), '1'); } catch { /* ignore */ }
    setHidden(true);
  };

  return (
    <div style={BOX} role="status" data-testid="reward-notice">
      <p style={TITLE}>You earned {s.percent_off}% off your next month</p>
      <p style={BODY}>
        A friend joined with your invite code. {rewardNoticeText(s)}
      </p>
      <Button size="small" onClick={dismiss} style={{ borderRadius: 8, marginTop: '0.6rem', fontFamily: "'Inter', sans-serif" }}>
        Dismiss
      </Button>
    </div>
  );
}
