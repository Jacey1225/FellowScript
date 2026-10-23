import React from 'react';

export function ToggleRow({ title, helper, checked, onChange, disabled = false }) {
  return (
    <div className="ff-toggle" role="switch" aria-checked={checked} aria-disabled={disabled || undefined} tabIndex={disabled ? -1 : 0}
      onClick={() => !disabled && onChange(!checked)}
      onKeyDown={(e) => { if (!disabled && (e.key === ' ' || e.key === 'Enter')) { e.preventDefault(); onChange(!checked); } }}>
      <div>
        <div className="ff-toggle__title">{title}</div>
        {helper && <div className="ff-helper">{helper}</div>}
      </div>
      <span className="ff-switch" aria-checked={checked} aria-hidden="true" />
    </div>
  );
}

// options: [{ value, label }]. multi=false -> radio semantics, true -> aria-pressed toggles.
export function ChipGroup({ options, value, onChange, multi = false, addOn = false, label }) {
  const selected = (v) => (multi ? (value || []).includes(v) : value === v);
  const pick = (v) => {
    if (multi) onChange(selected(v) ? value.filter((x) => x !== v) : [...(value || []), v]);
    else onChange(v);
  };
  return (
    <div className="ff-chips" role={multi ? 'group' : 'radiogroup'} aria-label={label}>
      {options.map((o) => (
        <button key={o.value} type="button" className={`ff-chip${addOn ? ' ff-chip--addon' : ''}`}
          {...(multi ? { 'aria-pressed': selected(o.value) } : { role: 'radio', 'aria-checked': selected(o.value) })}
          onClick={() => pick(o.value)}>
          {selected(o.value) ? '✓' : addOn ? '+' : null}{o.label}
        </button>
      ))}
    </div>
  );
}

export function Segmented({ options, value, onChange, label }) {
  return (
    <div className="ff-seg" role="radiogroup" aria-label={label}>
      {options.map((o) => (
        <button key={o.value} type="button" role="radio" aria-checked={value === o.value} className="ff-seg__item"
          onClick={() => onChange(o.value)}>{o.label}</button>
      ))}
    </div>
  );
}

export function RadioList({ options, value, onChange, label }) {
  return (
    <div role="radiogroup" aria-label={label}>
      {options.map((o) => (
        <button key={o.value} type="button" role="radio" aria-checked={value === o.value} className="ff-radio" onClick={() => onChange(o.value)}>
          <span>{o.label}{o.helper && <span className="ff-helper" style={{ display: 'block' }}>{o.helper}</span>}</span>
          <span className="ff-radio__dot" />
        </button>
      ))}
    </div>
  );
}

export function NumberStepper({ value, onChange, min = 1, max = 99, unit = '', label }) {
  return (
    <div className="ff-stepper-num" role="group" aria-label={label}>
      <button type="button" className="ff-round" aria-label="Decrease" disabled={value <= min} onClick={() => onChange(Math.max(min, value - 1))}>−</button>
      <div className="ff-stepper-num__value" aria-live="polite">{unit ? `${value} ${unit}` : value}</div>
      <button type="button" className="ff-round" aria-label="Increase" disabled={value >= max} onClick={() => onChange(Math.min(max, value + 1))}>+</button>
    </div>
  );
}
