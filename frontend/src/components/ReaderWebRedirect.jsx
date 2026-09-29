import React from 'react';
import { Navigate } from 'react-router-dom';
import { isDesktopApp } from '../lib/desktopScope.js';

// The web reader is retired: any ordinary browser that reaches /reader is
// sent to /download, which picks the desktop or iOS download itself by
// device (Download.jsx). The Tauri desktop shell loads this same bundle and
// its whole purpose is the reader, so it passes straight through.
export default function ReaderWebRedirect({ children }) {
  if (isDesktopApp()) return children;
  return <Navigate to="/download" replace />;
}
