// Task 20261118-public-membership-page: keeps the legacy
// #/account?subscribe=1&seats=N link contract working by sending it to the
// public /membership page. Runs before Account's own signed-out redirect, so
// it works signed out too. Only the literal subscribe=1 is honored; seats is
// clamped and rebuilt into a fixed internal path (no URL param is ever used
// as a redirect target). Plain /account, and the desktop shell (which does
// not carry /membership), are untouched.
import React from 'react';
import { Navigate, useLocation } from 'react-router-dom';
import { isDesktopApp } from '../lib/desktopScope.js';
import { membershipPath } from '../lib/pendingPurchase.js';

export default function AccountSubscribeAlias({ children }) {
  const { search } = useLocation();
  const params = new URLSearchParams(search);
  if (!isDesktopApp() && params.get('subscribe') === '1') {
    return <Navigate replace to={membershipPath(params.get('seats'))} />;
  }
  return children;
}
