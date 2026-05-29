import React from 'react';
import { createRoot } from 'react-dom/client';
import { ConfigProvider } from 'antd';
import App from './App.jsx';
import { AuthProvider } from './context/AuthContext.jsx';
import { fsTheme } from './theme.js';
import './styles/global.css';

// Apply saved theme before first paint to avoid flash
document.documentElement.setAttribute('data-theme', localStorage.getItem('fs_theme') || 'dark');

createRoot(document.getElementById('root')).render(
  <ConfigProvider theme={fsTheme}>
    <AuthProvider>
      <App />
    </AuthProvider>
  </ConfigProvider>
);
