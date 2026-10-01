import React from 'react';
import AdminActivityMonitoring from '../components/AdminActivityMonitoring.jsx';
import { AdminPageHeader } from '../components/AdminShell.jsx';

// Task 20261001-admin-account-redesign: the existing activity-monitoring
// charts promoted to their own section; data and behavior unchanged.
export default function AdminTrends() {
  return (
    <>
      <AdminPageHeader title="Trends" />
      <AdminActivityMonitoring />
    </>
  );
}
