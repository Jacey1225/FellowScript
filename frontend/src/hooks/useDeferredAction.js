// Task 20261030-user-profiles: client-side grace period for an action the
// server cannot undo (unfriend). start() runs `commit` after `delayMs` unless
// undo() is called first; leaving the screen (unmount) commits immediately.
import { useCallback, useEffect, useRef } from 'react';

export function useDeferredAction(delayMs = 6000) {
  const pending = useRef(null); // { timer, commit }

  const flush = useCallback(() => {
    const p = pending.current;
    if (!p) return;
    pending.current = null;
    clearTimeout(p.timer);
    p.commit();
  }, []);

  const start = useCallback((commit) => {
    flush();
    pending.current = { commit, timer: setTimeout(flush, delayMs) };
  }, [flush, delayMs]);

  const undo = useCallback(() => {
    const p = pending.current;
    if (!p) return false;
    clearTimeout(p.timer);
    pending.current = null;
    return true;
  }, []);

  useEffect(() => flush, [flush]);
  return { start, undo, flush };
}
