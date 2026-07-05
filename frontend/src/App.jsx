import React from 'react';
import { HashRouter, Routes, Route, Navigate } from 'react-router-dom';
import Dashboard from './pages/Dashboard.jsx';
import Reader from './pages/Reader.jsx';
import Account from './pages/Account.jsx';
import SignIn from './pages/SignIn.jsx';
import Privacy from './pages/Privacy.jsx';
import Terms from './pages/Terms.jsx';

export default function App() {
  return (
    <HashRouter>
      <Routes>
        <Route path="/"        element={<Dashboard />} />
        <Route path="/reader"  element={<Reader />} />
        <Route path="/account" element={<Account />} />
        <Route path="/signin"  element={<SignIn />} />
        <Route path="/privacy" element={<Privacy />} />
        <Route path="/terms"   element={<Terms />} />
        <Route path="*"        element={<Navigate to="/" replace />} />
      </Routes>
    </HashRouter>
  );
}
