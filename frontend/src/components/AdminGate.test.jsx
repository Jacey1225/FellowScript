// Route-guard test for AdminGate.jsx (step 9 of
// .claude/pipeline/20260811-error-debug-agent-admin-page/architecture.json).
//
// AdminGate is explicitly documented as defense-in-depth UX only -- it can
// only synchronously handle the "no session at all" (fully unauthenticated)
// case, since there is no client-visible is_admin field. This proves that
// one case actually redirects to /signin, and that a signed-in user (even a
// non-admin one, since AdminGate has no way to know) is allowed through to
// its children -- the real 401/403 enforcement is each page's own fetch,
// covered separately in AdminDetections.test.jsx / AdminDetectionDetail.test.jsx.
//
// Run with: cd frontend && npm test -- --run src/components/AdminGate.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import AdminGate from './AdminGate.jsx';

afterEach(() => cleanup());

const mockUseAuth = vi.fn();
vi.mock('../context/AuthContext.jsx', () => ({
  useAuth: () => mockUseAuth(),
}));

function renderGate(initialUser) {
  mockUseAuth.mockReturnValue({ user: initialUser });
  return render(
    <MemoryRouter initialEntries={['/admin']}>
      <Routes>
        <Route path="/admin" element={<AdminGate><div>Admin Content</div></AdminGate>} />
        <Route path="/signin" element={<div>Sign In Page</div>} />
      </Routes>
    </MemoryRouter>
  );
}

describe('AdminGate — unauthenticated redirect', () => {
  test('no session at all redirects to /signin and never renders admin children', async () => {
    renderGate(null);

    expect(await screen.findByText('Sign In Page')).toBeInTheDocument();
    expect(screen.queryByText('Admin Content')).not.toBeInTheDocument();
  });
});

describe('AdminGate — authenticated pass-through', () => {
  test('a signed-in user is allowed through to render children (real admin check happens per-page)', () => {
    renderGate({ user_id: 'u1', username: 'jaceysimpson' });

    expect(screen.getByText('Admin Content')).toBeInTheDocument();
    expect(screen.queryByText('Sign In Page')).not.toBeInTheDocument();
  });
});
