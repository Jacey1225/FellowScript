import React from 'react';

export function FormRoot({ children, className = '', ...rest }) {
  return <div className={`fs-form ${className}`.trim()} {...rest}>{children}</div>;
}

export function FormCard({ eyebrow, title, children, className = '' }) {
  return (
    <section className={`ff-card ${className}`.trim()}>
      {(eyebrow || title) && (
        <div>
          {eyebrow && <div className="ff-card__eyebrow">{eyebrow}</div>}
          {title && <h3 className="ff-card__title">{title}</h3>}
        </div>
      )}
      {children}
    </section>
  );
}

// steps: ['Content','Style','Publish']; current index; maxReachable index; onSelect(i)
export function StepperRail({ steps, current, maxReachable, onSelect }) {
  return (
    <ol className="ff-rail" aria-label="Progress">
      {steps.map((name, i) => {
        const done = i < current;
        return (
          <li key={name} className="ff-rail__step" data-done={done} aria-current={i === current ? 'step' : undefined}>
            <button type="button" className="ff-rail__hit" disabled={i > maxReachable} onClick={() => onSelect(i)}
              aria-label={`Step ${i + 1} of ${steps.length}, ${name}${i === current ? ', current' : done ? ', done' : ''}`}>
              <span className="ff-rail__node">{done ? '✓' : null}</span>
              <span className="ff-rail__label">{name}</span>
            </button>
          </li>
        );
      })}
    </ol>
  );
}

// Primary stays focusable (aria-disabled) so activating it runs validation (D8).
export function StickyActionBar({
  primaryLabel, onPrimary, primaryDisabled = false, saving = false, secondaryLabel, onSecondary,
  secondaryDanger = false, variant = 'modal', primaryType = 'button',
}) {
  const handle = (e) => { if (saving) { e.preventDefault(); return; } onPrimary?.(e); };
  return (
    <div className={`ff-actions${variant === 'panel' ? ' ff-actions--panel' : ''}`}>
      {secondaryLabel && (
        <button type="button" className={`ff-btn ${secondaryDanger ? 'ff-btn--danger' : 'ff-btn--secondary'}`} onClick={onSecondary}>{secondaryLabel}</button>
      )}
      <button type={primaryType} className="ff-btn ff-btn--primary" aria-disabled={primaryDisabled || saving || undefined} onClick={handle}>
        {saving ? <span role="status" aria-label="Saving">…</span> : primaryLabel}
      </button>
    </div>
  );
}

export function FormErrorSummary({ items, onSelect }) {
  if (!items?.length) return null;
  return (
    <div className="ff-alert" role="alert">
      <div className="ff-alert__title">{items.length === 1 ? '1 thing needs attention' : `${items.length} things need attention`}</div>
      {items.map((it) => (
        <button key={it.id} type="button" className="ff-alert__link" onClick={() => onSelect?.(it.id)}>{it.name}</button>
      ))}
    </div>
  );
}

export function RetryCard({ message = 'We could not save. Check your connection.', onRetry, onDismiss }) {
  return (
    <div className="ff-alert" role="alert">
      <div className="ff-alert__title">{message}</div>
      <div style={{ display: 'flex', gap: 12 }}>
        <button type="button" className="ff-btn ff-btn--secondary" onClick={onRetry}>Try again</button>
        <button type="button" className="ff-alert__link" onClick={onDismiss}>Dismiss</button>
      </div>
    </div>
  );
}

export function InfoCard({ children }) {
  return <div className="ff-info" role="note">{children}</div>;
}
