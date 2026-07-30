import React from 'react';
import { createRoot } from 'react-dom/client';
import { ConfigProvider } from 'antd';
import App from './App.jsx';
import { AuthProvider } from './context/AuthContext.jsx';
import { fsTheme } from './theme.js';
import './styles/global.css';
import 'dockview-react/dist/styles/dockview.css';
import './styles/reader-dock.css';

// Apply saved theme before first paint to avoid flash
document.documentElement.setAttribute('data-theme', localStorage.getItem('fs_theme') || 'dark');

// Google OAuth returns the id_token in the URL fragment (#id_token=...). Because
// this app uses HashRouter, that fragment would be parsed as a bogus route and the
// sign-in silently lost. Capture it BEFORE React/HashRouter mounts, stash it, and
// route to the sign-in page which finishes the exchange.
(() => {
  const raw = window.location.hash.slice(1);
  if (raw.includes('id_token=')) {
    const token = new URLSearchParams(raw).get('id_token');
    if (token) sessionStorage.setItem('pending_google_id_token', token);
    window.location.hash = '#/signin';
  } else if (raw.includes('error=') && !raw.startsWith('/')) {
    sessionStorage.setItem('pending_google_error',
      new URLSearchParams(raw).get('error') || 'error');
    window.location.hash = '#/signin';
  }
})();

createRoot(document.getElementById('root')).render(
  <ConfigProvider theme={fsTheme}>
    <AuthProvider>
      <App />
    </AuthProvider>
  </ConfigProvider>
);
