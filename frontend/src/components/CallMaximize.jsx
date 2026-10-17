import React, { useEffect, useRef } from 'react';
import { CompressOutlined } from '@ant-design/icons';

// Shared pieces for tap-to-maximize on the web call UI (task
// 20261016-call-maximize-tiles). State is local to each surface and never
// synced to other participants.

// Labeled, 44px "Back to everyone" control. Takes focus when it appears so a
// keyboard / screen reader user lands on the way back.
export function MaxBackButton({ onClick }) {
  const ref = useRef(null);
  useEffect(() => { ref.current?.focus(); }, []);
  return (
    <button ref={ref} type="button" className="call-max-back" onClick={onClick}>
      <CompressOutlined aria-hidden="true" />
      <span>Back to everyone</span>
    </button>
  );
}

// Escape returns to the normal layout while `active`. Ignored while focus is
// inside a menu or dialog so those keep their own Escape behavior.
export function useEscapeToClose(active, onClose) {
  const closeRef = useRef(onClose);
  closeRef.current = onClose;
  useEffect(() => {
    if (!active) return undefined;
    const onKey = e => {
      if (e.key !== 'Escape' || e.defaultPrevented) return;
      if (document.activeElement?.closest?.('[role="menu"],[role="dialog"]')) return;
      closeRef.current();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [active]);
}
