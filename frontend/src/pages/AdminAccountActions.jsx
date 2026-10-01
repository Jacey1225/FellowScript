import React from 'react';
import AdminMembershipGrant from '../components/AdminMembershipGrant.jsx';
import { AdminPageHeader } from '../components/AdminShell.jsx';

// Task 20261001-admin-account-redesign: the one existing account-level admin
// action (grant individual plan). No lookup/set-status endpoints exist.
export default function AdminAccountActions() {
  return (
    <>
      <AdminPageHeader title="Account actions" />
      <AdminMembershipGrant />
    </>
  );
}
