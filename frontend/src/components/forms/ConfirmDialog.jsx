import React, { useEffect, useRef } from 'react';
import { useFocusTrap } from '../../hooks/useFocusTrap.js';
import { FormRoot } from './Layout.jsx';

// Tier 2 confirm (spec 9.2): title names the object, one-line consequence,
// "Keep" (default focus) and the destructive verb on the right.
export function ConfirmDialog({ title, body, keepLabel = 'Keep', confirmLabel, onKeep, onConfirm }) {
  const ref = useRef(null);
  useFocusTrap(true, ref);
  useEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape') onKeep?.(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onKeep]);
  return (
    <FormRoot style={{ position: 'fixed', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'rgba(0,0,0,0.6)', zIndex: 1000 }}>
      <div ref={ref} className="ff-modal ff-modal--confirm" role="alertdialog" aria-modal="true" aria-labelledby="ff-confirm-title" aria-describedby="ff-confirm-body">
        <div className="ff-body">
          <h2 id="ff-confirm-title" className="ff-title">{title}</h2>
          <p id="ff-confirm-body" className="ff-helper" style={{ fontSize: 14 }}>{body}</p>
        </div>
        <div className="ff-actions">
          <button type="button" className="ff-btn ff-btn--secondary" autoFocus onClick={onKeep}>{keepLabel}</button>
          <button type="button" className="ff-btn ff-btn--danger" onClick={onConfirm}>{confirmLabel}</button>
        </div>
      </div>
    </FormRoot>
  );
}
