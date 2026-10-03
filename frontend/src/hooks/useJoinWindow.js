import { useEffect, useState } from 'react';
import { isJoinWindowOpen } from '../lib/sessionAccess.js';

// Live join-window state for one session. Re-evaluates every second (iOS does
// the same) and only re-renders when the answer flips, so a card sitting
// before its window opens enables Join without a reload.
export function useJoinWindow(session) {
  const [open, setOpen] = useState(() => isJoinWindowOpen(session));
  useEffect(() => {
    const evaluate = () => setOpen(isJoinWindowOpen(session));
    evaluate();
    const id = setInterval(evaluate, 1000);
    return () => clearInterval(id);
  }, [session?.time_start, session?.time_end]);
  return open;
}
