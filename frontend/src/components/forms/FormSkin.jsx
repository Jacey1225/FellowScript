import React from 'react';
import { ConfigProvider } from 'antd';
import { formTheme } from '../../lib/formTokens.js';

// Wrap an antd-based form surface so its controls, modals and popovers use the
// forms-restyle tokens (iOS amber gold, gray glass fields, system font) without
// touching the rest of the app's theme. Portaled antd modals inherit the theme
// through ConfigProvider context.
export function FormSkin({ children, className = '', style }) {
  return (
    <ConfigProvider theme={formTheme}>
      <div className={`fs-form ${className}`.trim()} style={style}>{children}</div>
    </ConfigProvider>
  );
}

// Card style shared by antd card sections inside a FormSkin (gray glass, radius 20).
export const FORM_CARD_STYLE = {
  background: 'rgba(154,154,154,0.16)',
  border: '1px solid rgba(255,255,255,0.14)',
  borderRadius: 20,
  marginBottom: '1.25rem',
};
