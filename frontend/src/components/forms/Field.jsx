import React, { useEffect, useId, useState } from 'react';

// Counter shows at >=80% of the limit (singles) or whenever provided for textareas near the limit.
export function shouldShowCounter(length, maxLength) {
  return Boolean(maxLength) && length * 5 >= maxLength * 4;
}

// Label above a 48px field, helper/error slot, optional counter and secure reveal.
// Keeps whatever autoComplete / inputMode / type the caller passes.
export function Field({
  label, required = false, optional = false, value, onChange, error = null, helper = null,
  maxLength, multiline = false, secure = false, disabled = false, disabledReason = null,
  leading = null, inputRef, id: idProp, className = '', ...inputProps
}) {
  const autoId = useId();
  const id = idProp || autoId;
  const descId = `${id}-desc`;
  const [revealed, setRevealed] = useState(false);
  // Re-mask after 10 seconds (spec 9.1.1); reveal is never persisted.
  useEffect(() => {
    if (!revealed) return undefined;
    const t = setTimeout(() => setRevealed(false), 10000);
    return () => clearTimeout(t);
  }, [revealed]);
  const Tag = multiline ? 'textarea' : 'input';
  const len = (value || '').length;
  const note = error || (disabled && disabledReason) || helper;
  const type = secure ? (revealed ? 'text' : 'password') : (inputProps.type || 'text');
  return (
    <div className={`ff-field ${className}`.trim()}>
      <label className="ff-label" htmlFor={id}>
        {label}
        {required && <span className="ff-req" aria-hidden="true">*</span>}
        {optional && <span className="ff-opt">(optional)</span>}
      </label>
      <div className={`ff-control${multiline ? ' ff-control--textarea' : ''}${error ? ' ff-control--error' : ''}${disabled ? ' ff-control--disabled' : ''}`}>
        {leading}
        <Tag
          {...inputProps}
          ref={inputRef}
          id={id}
          type={multiline ? undefined : type}
          className="ff-input"
          value={value}
          maxLength={maxLength}
          disabled={disabled}
          aria-required={required || undefined}
          aria-invalid={error ? 'true' : undefined}
          aria-describedby={note ? descId : undefined}
          onChange={(e) => onChange?.(e.target.value, e)}
        />
        {secure && (
          <button type="button" className="ff-icon-btn" aria-label={revealed ? 'Hide password' : 'Show password'}
            onClick={() => setRevealed((r) => !r)} onBlur={() => setRevealed(false)}>
            {revealed ? '🙈' : '👁'}
          </button>
        )}
      </div>
      <div className="ff-foot">
        {note && (
          <div id={descId} className={error ? 'ff-error' : 'ff-helper'}>
            {error && <span aria-hidden="true">⚠</span>}<span>{note}</span>
          </div>
        )}
        {shouldShowCounter(len, maxLength) && (
          <span className={`ff-counter${len >= maxLength ? ' ff-counter--limit' : ''}`}>{len} / {maxLength}</span>
        )}
      </div>
    </div>
  );
}
