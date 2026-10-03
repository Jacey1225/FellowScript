import React, { createContext, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useAuth } from './AuthContext.jsx';
import { CAPABILITIES_OFF, fetchCapabilities } from '../lib/capabilities.js';

// Task 20261002-shared-foundation step 8. Holds the last /app/capabilities
// result. One fetch per launch / sign-in (user change) / foreground return;
// no polling and no retry loop. Signed out: nothing is fetched and everything
// stays off.
const DEFAULT_VALUE = {
  ...CAPABILITIES_OFF,
  isEnabled: () => false,
  refresh: async () => CAPABILITIES_OFF,
};

export const CapabilitiesContext = createContext(DEFAULT_VALUE);

const MIN_FOREGROUND_GAP_MS = 15000;
// Task 20261003-web-reader-ios-parity (step 5): a failed first fetch (cold
// network when the desktop webview opens, a 5s timeout) used to leave every
// server-gated feature (threads, delete, publish, join requests, Explore row)
// hidden for the whole session until the app was backgrounded and refocused.
// Retry a FAILED fetch at most twice (not a loop, not polling). A real
// response, even "everything off", is never retried.
export const CAPABILITIES_RETRY_DELAYS_MS = [3000, 10000];

export function CapabilitiesProvider({ children }) {
  const auth = useAuth();
  const userId = auth?.user?.user_id || null;
  const [caps, setCaps] = useState(CAPABILITIES_OFF);
  const lastFetchRef = useRef(0);
  const seqRef = useRef(0);

  const refresh = useCallback(async () => {
    if (!userId) { setCaps(CAPABILITIES_OFF); return CAPABILITIES_OFF; }
    const seq = ++seqRef.current;
    lastFetchRef.current = Date.now();
    const next = await fetchCapabilities();
    if (seq === seqRef.current) setCaps(next);
    return next;
  }, [userId]);

  useEffect(() => {
    if (!userId) { seqRef.current += 1; setCaps(CAPABILITIES_OFF); return undefined; }
    let cancelled = false;
    const timers = [];
    const attempt = async (i) => {
      const result = await refresh();
      if (cancelled || result !== CAPABILITIES_OFF || i >= CAPABILITIES_RETRY_DELAYS_MS.length) return;
      timers.push(setTimeout(() => attempt(i + 1), CAPABILITIES_RETRY_DELAYS_MS[i]));
    };
    attempt(0);
    const onVisible = () => {
      if (document.visibilityState !== 'visible') return;
      if (Date.now() - lastFetchRef.current < MIN_FOREGROUND_GAP_MS) return;
      refresh();
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      cancelled = true;
      timers.forEach(clearTimeout);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, [userId, refresh]);

  const value = useMemo(() => ({
    ...caps,
    isEnabled: (name) => caps.features[name] === true,
    refresh,
  }), [caps, refresh]);

  return <CapabilitiesContext.Provider value={value}>{children}</CapabilitiesContext.Provider>;
}
