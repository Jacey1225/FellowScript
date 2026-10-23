import React, { useCallback, useEffect, useRef, useState } from 'react';

// Tier-1 destructive pattern (spec 9.2 / SX6): hide the item, show an "Undo"
// snackbar for 6 seconds, and only run `commit` (the real delete) when it
// expires. A newer delete commits the previous one first. Unmount commits too.
export function useUndoDelete(ms = 6000) {
  const [message, setMessage] = useState(null);
  const pending = useRef(null);
  const timer = useRef(null);

  const flush = useCallback(() => {
    clearTimeout(timer.current);
    const p = pending.current;
    pending.current = null;
    setMessage(null);
    p?.commit();
  }, []);

  const schedule = useCallback(({ message: m, hide, restore, commit }) => {
    if (pending.current) flush();
    hide();
    pending.current = { restore, commit };
    setMessage(m);
    timer.current = setTimeout(flush, ms);
  }, [flush, ms]);

  const undo = useCallback(() => {
    clearTimeout(timer.current);
    const p = pending.current;
    pending.current = null;
    setMessage(null);
    p?.restore();
  }, []);

  useEffect(() => () => { clearTimeout(timer.current); pending.current?.commit(); }, []);

  const snackbar = message ? (
    <div className="ff-snackbar fs-form" role="status">
      <span>{message}</span>
      <button type="button" className="ff-link" onClick={undo}>Undo</button>
    </div>
  ) : null;

  return { schedule, snackbar };
}
