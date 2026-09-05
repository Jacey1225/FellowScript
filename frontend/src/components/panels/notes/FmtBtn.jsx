import React from 'react';
import { hoverStyleHandlers } from './noteFormat.js';

// Formatting toolbar button — uses onMouseDown so it never steals focus
// from the contentEditable body, preserving the user's text selection.
export default function FmtBtn({ children, title, onMouseDown, active }) {
  const base = {
    background:  active ? 'rgba(255,198,26,0.28)' : 'rgba(255,198,26,0.10)',
    borderColor: active ? 'rgba(255,255,255,0.39)' : 'rgba(255,255,255,0.168)',
    color:       active ? 'var(--gold)'            : 'rgba(242,242,242,0.80)',
  };
  const hoverHandlers = hoverStyleHandlers(
    {
      background:  active ? 'rgba(255,198,26,0.38)' : 'rgba(255,198,26,0.22)',
      borderColor: 'rgba(255,255,255,0.42)',
      color:       'var(--gold)',
      transform:   'translateY(-1px)',
    },
    { ...base, transform: 'translateY(0)' }
  );
  return (
    <button
      title={title}
      onMouseDown={onMouseDown}
      style={{
        ...base,
        border: 'none',
        borderRadius: 10,
        cursor: 'pointer',
        fontSize: '0.92rem',
        minWidth: 40,
        height: 40,
        padding: '0 0.85rem',
        lineHeight: 1,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        transition: 'background 0.15s, border-color 0.15s, color 0.15s, transform 0.12s',
        userSelect: 'none',
        flexShrink: 0,
        boxShadow: active ? 'inset 0 0 0 1px rgba(255,198,26,0.18)' : 'none',
      }}
      {...hoverHandlers}
    >
      {children}
    </button>
  );
}
