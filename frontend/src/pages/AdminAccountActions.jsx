import React from 'react';
import AdminMembershipGrant from '../components/AdminMembershipGrant.jsx';
import AdminHomeMessages from '../components/AdminHomeMessages.jsx';
import { AdminPageHeader } from '../components/AdminShell.jsx';

// Task 20261001-admin-account-redesign: the one existing account-level admin
// action (grant individual plan). No lookup/set-status endpoints exist.
// Task 20261002-home-announcement-headline adds the Home announcements card.
export default function AdminAccountActions() {
  return (
    <>
      <AdminPageHeader title="Account actions" />
      <AdminMembershipGrant />
      <AdminHomeMessages />
    </>
  );
}
