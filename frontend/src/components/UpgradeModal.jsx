import React, { useEffect, useRef, useSyncExternalStore } from 'react';
import { Modal, Button } from 'antd';
import { CrownOutlined } from '@ant-design/icons';
import { useLocation, useNavigate } from 'react-router-dom';
import {
  getUpgradePrompt, subscribeUpgradePrompt, dismissUpgradePrompt,
  upgradeBody, UPGRADE_TITLE, UPGRADE_CTA, scrollToSubscription,
} from '../lib/upgradePrompt.js';

// Task 20261002-free-plan-limits-ui: the single reusable "not available on the
// Free plan" modal. Mounted once (App.jsx); every blocked flow opens it via
// showUpgradePrompt(info) from lib/upgradePrompt.js.
export function useUpgradePrompt() {
  const s = useSyncExternalStore(subscribeUpgradePrompt, getUpgradePrompt, getUpgradePrompt);
  return s;
}

export default function UpgradeModal() {
  const s = useUpgradePrompt();
  const navigate = useNavigate();
  const location = useLocation();
  const subscribeRef = useRef(null);
  const triggerRef = useRef(null);
  const infoRef = useRef(null);
  if (s?.trigger) triggerRef.current = s.trigger;
  if (s?.info) infoRef.current = s.info; // keep copy stable during the exit animation
  const info = s?.info || infoRef.current;

  useEffect(() => {
    if (!s) return undefined;
    const t = setTimeout(() => subscribeRef.current?.focus?.(), 60);
    return () => clearTimeout(t);
  }, [s]);

  const close = (returnFocus = true) => {
    dismissUpgradePrompt();
    if (returnFocus) {
      const el = triggerRef.current;
      setTimeout(() => { try { el?.focus?.(); } catch { /* ignore */ } }, 0);
    }
  };

  const onSubscribe = () => {
    close(false);
    if (location.pathname !== '/account') navigate('/account');
    scrollToSubscription();
  };

  return (
    <Modal
      open={!!s}
      onCancel={() => close(true)}
      footer={null}
      closable={false}
      centered
      destroyOnHidden
      width="min(420px, calc(100vw - 32px))"
      className="fs-upgrade-modal"
      wrapClassName="fs-upgrade-modal-wrap"
      aria-labelledby="fs-upgrade-title"
      aria-describedby="fs-upgrade-body"
    >
      <div className="fs-upgrade-inner" data-testid="upgrade-modal">
        <div className="fs-upgrade-icon" aria-hidden="true"><CrownOutlined /></div>
        <h2 id="fs-upgrade-title" className="fs-upgrade-title">{UPGRADE_TITLE}</h2>
        <p id="fs-upgrade-body" className="fs-upgrade-body">
          {upgradeBody(info)} {UPGRADE_CTA}
        </p>
        <Button ref={subscribeRef} type="primary" block className="fs-upgrade-primary" onClick={onSubscribe}>
          Subscribe
        </Button>
        <Button type="text" block className="fs-upgrade-secondary" onClick={() => close(true)}>
          Not now
        </Button>
      </div>
    </Modal>
  );
}
