// Task 20261030-user-profiles: loads a profile with cache-then-refresh.
// Failed refresh with a cached profile keeps showing it (status 'stale');
// a 404 evicts the cache and shows the unavailable state; first-load failure
// with no cache is an error state, never a fabricated profile.
import { useCallback, useEffect, useRef, useState } from 'react';
import { fetchProfile } from '../lib/profileApi.js';
import { getCachedProfile, setCachedProfile, evictCachedProfile } from '../lib/profileCache.js';

// state: loading | ready | unavailable | error
export function useProfile(viewerId, targetId) {
  const cached = viewerId && targetId ? getCachedProfile(viewerId, targetId) : null;
  const [profile, setProfile] = useState(cached);
  const [state, setState] = useState(cached ? 'ready' : 'loading');
  const [refreshing, setRefreshing] = useState(!!cached);
  const [refreshFailed, setRefreshFailed] = useState(false);
  const seq = useRef(0);

  const load = useCallback(async () => {
    if (!viewerId || !targetId) return;
    const mine = ++seq.current;
    setRefreshFailed(false);
    const have = getCachedProfile(viewerId, targetId);
    if (have) { setProfile(have); setState('ready'); setRefreshing(true); } else { setState('loading'); setRefreshing(false); }
    try {
      const fresh = await fetchProfile(targetId);
      if (mine !== seq.current) return;
      setCachedProfile(viewerId, targetId, fresh);
      setProfile(fresh); setState('ready');
    } catch (err) {
      if (mine !== seq.current) return;
      if (err.status === 404) {
        evictCachedProfile(viewerId, targetId);
        setProfile(null); setState('unavailable');
      } else if (getCachedProfile(viewerId, targetId)) {
        setRefreshFailed(true); // keep the cached profile on screen
      } else {
        setProfile(null); setState('error');
      }
    } finally {
      if (mine === seq.current) setRefreshing(false);
    }
  }, [viewerId, targetId]);

  useEffect(() => { load(); return () => { seq.current += 1; }; }, [load]);

  // Local optimistic edits (bio saved, relationship flipped) also update cache.
  const patch = useCallback((fn) => {
    setProfile((prev) => {
      if (!prev) return prev;
      const next = fn(prev);
      setCachedProfile(viewerId, targetId, next);
      return next;
    });
  }, [viewerId, targetId]);

  const drop = useCallback(() => {
    evictCachedProfile(viewerId, targetId);
    setProfile(null); setState('unavailable');
  }, [viewerId, targetId]);

  return { profile, state, refreshing, refreshFailed, reload: load, patch, drop };
}
