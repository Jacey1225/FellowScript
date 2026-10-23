import React from 'react';
import { FormRoot, FormCard } from './Layout.jsx';

// Type C skeleton (spec 4): centered 420px column, wordmark, title + subtitle, glass card.
export function AuthPage({ title, subtitle, children, footer, wordmark = true }) {
  return (
    <FormRoot className="ff-authpage">
      <div className="ff-page ff-page--auth">
        {wordmark && (
          <div className="ff-wordmark" aria-hidden="true">FellowScript</div>
        )}
        {title && (
          <div className="ff-authhead">
            <h1 className="ff-title ff-title--center">{title}</h1>
            {subtitle && <p className="ff-helper ff-center" style={{ fontSize: 14 }}>{subtitle}</p>}
          </div>
        )}
        <FormCard>{children}</FormCard>
        {footer}
      </div>
    </FormRoot>
  );
}

// Six-box one-time-code entry: one real input owns focus, autofill (one-time-code) and paste.
export function CodeField({ label, value, onChange, length = 6, error = null, id = 'ff-code', autoFocus = false }) {
  const chars = (value || '').split('');
  return (
    <div className="ff-field">
      <label className="ff-label" htmlFor={id}>{label}</label>
      <div className="ff-code">
        <input id={id} className="ff-code__input" inputMode="numeric" autoComplete="one-time-code" maxLength={length}
          autoFocus={autoFocus} value={value} aria-invalid={error ? 'true' : undefined}
          aria-describedby={error ? `${id}-err` : undefined}
          onChange={(e) => onChange(e.target.value.replace(/\D/g, '').slice(0, length))} />
        <div className="ff-code__boxes" aria-hidden="true">
          {Array.from({ length }).map((_, i) => (
            <span key={i} className={`ff-code__box${i === Math.min(chars.length, length - 1) ? ' ff-code__box--active' : ''}`}>{chars[i] || ''}</span>
          ))}
        </div>
      </div>
      {error && <div id={`${id}-err`} className="ff-error"><span aria-hidden="true">⚠</span><span>{error}</span></div>}
    </div>
  );
}
