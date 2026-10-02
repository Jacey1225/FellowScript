// Task 20261002-shared-foundation step 9: TermsGate shown only when signed in and terms_current false.
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';

let mockUser = { user_id: 'u1' };
let mockCaps = { termsCurrent: false, refresh: vi.fn() };
vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => ({ user: mockUser, signOut: vi.fn() }) }));
vi.mock('../hooks/useCapabilities.js', () => ({ useCapabilities: () => mockCaps }));
import TermsGate from './TermsGate.jsx';

const mount = () => render(<MemoryRouter><TermsGate /></MemoryRouter>);
afterEach(() => { cleanup(); mockUser = { user_id: 'u1' }; mockCaps = { termsCurrent: false, refresh: vi.fn() }; });

describe('TermsGate', () => {
  test('signed in and terms_current false: modal shown', () => {
    mount();
    expect(screen.getByText('Our Terms of Service have been updated')).toBeTruthy();
    expect(screen.getByText('I Agree')).toBeTruthy();
  });
  test('terms current: nothing', () => {
    mockCaps = { termsCurrent: true, refresh: vi.fn() };
    mount();
    expect(screen.queryByText('I Agree')).toBeNull();
  });
  test('signed out with terms_current false: nothing', () => {
    mockUser = null;
    mount();
    expect(screen.queryByText('I Agree')).toBeNull();
  });
  test('default (endpoint failed => termsCurrent true): nothing', () => {
    mockCaps = { termsCurrent: undefined, refresh: vi.fn() };
    mount();
    expect(screen.queryByText('I Agree')).toBeNull();
  });
});
