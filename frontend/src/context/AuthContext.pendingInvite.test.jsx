// Task 20260929-group-invite-links testing: sign-out drops any pending invite.
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, fireEvent } from '@testing-library/react';
import { AuthProvider, useAuth } from './AuthContext.jsx';
import { setPendingInvite, getPendingInvite } from '../lib/pendingInvite.js';

afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

function Btn() { const { signOut } = useAuth(); return <button onClick={signOut}>out</button>; }

test('signOut clears the pending invite', () => {
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue({}));
  vi.stubGlobal('localStorage', { getItem: () => null, setItem() {}, removeItem() {} });
  setPendingInvite('A'.repeat(43));
  render(<AuthProvider><Btn /></AuthProvider>);
  expect(getPendingInvite()).toBe('A'.repeat(43));
  fireEvent.click(screen.getByText('out'));
  expect(getPendingInvite()).toBeNull();
});
