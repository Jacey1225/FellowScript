import React from 'react';
import { HashRouter, Routes, Route, Navigate } from 'react-router-dom';
import Home from './pages/Home.jsx';
import Reader from './pages/Reader.jsx';
import Account from './pages/Account.jsx';
import SignIn from './pages/SignIn.jsx';
import ForgotPassword from './pages/ForgotPassword.jsx';
import ResetPassword from './pages/ResetPassword.jsx';
import VerifyMfa from './pages/VerifyMfa.jsx';
import Privacy from './pages/Privacy.jsx';
import Terms from './pages/Terms.jsx';
import AdminGate from './components/AdminGate.jsx';
import MobileBlockGate from './components/MobileBlockGate.jsx';
import DesktopRouteGuard from './components/DesktopRouteGuard.jsx';
import AdminDetections from './pages/AdminDetections.jsx';
import AdminDetectionDetail from './pages/AdminDetectionDetail.jsx';

export default function App() {
  return (
    <HashRouter>
      {/* Restricts the Tauri desktop shell to lib/desktopScope.js's
          DESKTOP_ALLOWED_ROUTES (task 20260906-desktop-scope-lockdown); a
          no-op in the ordinary web frontend. See DesktopRouteGuard.jsx. */}
      <DesktopRouteGuard>
        <Routes>
          <Route path="/"       element={<Home />} />
          <Route path="/reader" element={<MobileBlockGate><Reader /></MobileBlockGate>} />
          <Route path="/account"   element={<Account />} />
          <Route path="/signin"    element={<SignIn />} />
          <Route path="/forgot-password" element={<ForgotPassword />} />
          <Route path="/reset-password"  element={<ResetPassword />} />
          <Route path="/verify-2fa"      element={<VerifyMfa />} />
          <Route path="/privacy"   element={<Privacy />} />
          <Route path="/terms"     element={<Terms />} />
          {/* Hidden admin-only surface: not linked from AppNav or any other
              nav/menu component. Reachable only by navigating to the URL
              directly. Server-side `require_admin` is the real enforcement;
              AdminGate is defense-in-depth UX only. See design-notes.md §0. */}
          <Route path="/admin" element={<AdminGate><AdminDetections /></AdminGate>} />
          <Route path="/admin/detections/:id" element={<AdminGate><AdminDetectionDetail /></AdminGate>} />
          <Route path="*"          element={<Navigate to="/" replace />} />
        </Routes>
      </DesktopRouteGuard>
    </HashRouter>
  );
}
