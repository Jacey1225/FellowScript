import React from 'react';

// Accessible switch for "Accept join requests" (design A). role=switch,
// aria-checked, Space/Enter toggle (native button), 44px target.
export default function AcceptRequestsSwitch({ checked, onChange, disabled, error }) {
  return (
    <div className="jr-switch-row">
      <div className="jr-switch-text">
        <span id="jr-switch-label" className="jr-switch-label">Accept join requests</span>
        <span id="jr-switch-help" className="jr-helper">People can ask to join. You approve each request.</span>
        {error && <span className="jr-error" role="alert">{error}</span>}
      </div>
      <button
        type="button"
        role="switch"
        aria-checked={!!checked}
        aria-labelledby="jr-switch-label"
        aria-describedby="jr-switch-help"
        className={`jr-switch${checked ? ' jr-switch--on' : ''}`}
        onClick={() => onChange(!checked)}
        disabled={disabled}
      >
        <span className="jr-switch-knob" aria-hidden="true" />
      </button>
    </div>
  );
}
