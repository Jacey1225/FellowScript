// Task 20261007-email-verification: verify landing page.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor } from '@testing-library/react';
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom';

vi.mock('../components/Seo.jsx', () => ({ default: () => null }));
vi.mock('../lib/emailVerificationApi.js', () => ({ verifyEmailToken: vi.fn() }));
import { verifyEmailToken } from '../lib/emailVerificationApi.js';
import VerifyEmail from './VerifyEmail.jsx';

function Loc() { const l = useLocation(); return <div data-testid="loc">{l.pathname + l.search}</div>; }
function renderAt(url, strict = false) {
  const tree = (
    <MemoryRouter initialEntries={[url]}>
      <Loc />
      <Routes>
        <Route path="/verify-email" element={<VerifyEmail />} />
        <Route path="*" element={<div />} />
      </Routes>
    </MemoryRouter>
  );
  return render(strict ? <React.StrictMode>{tree}</React.StrictMode> : tree);
}

beforeEach(() => { verifyEmailToken.mockReset(); });
afterEach(() => cleanup());

describe('VerifyEmail', () => {
  test('no token: invalid message, no request made', () => {
    renderAt('/verify-email');
    expect(screen.getByText('This verification link is invalid or has expired.')).toBeInTheDocument();
    expect(verifyEmailToken).not.toHaveBeenCalled();
  });

  test('valid token: POSTs once, shows success, strips token from URL', async () => {
    verifyEmailToken.mockResolvedValue({ verified: true });
    renderAt('/verify-email?token=abc');
    expect(await screen.findByText('Email verified')).toBeInTheDocument();
    expect(verifyEmailToken).toHaveBeenCalledWith('abc');
    await waitFor(() => expect(screen.getByTestId('loc').textContent).toBe('/verify-email'));
  });

  test('failed token: uniform invalid message and token stripped', async () => {
    verifyEmailToken.mockImplementation(() => Promise.reject(new Error('x')));
    renderAt('/verify-email?token=bad');
    expect(await screen.findByText('This verification link is invalid or has expired.')).toBeInTheDocument();
    expect(screen.queryByText('Email verified')).toBeNull();
    await waitFor(() => expect(screen.getByTestId('loc').textContent).toBe('/verify-email'));
  });

  const EXPECTED = 'This verification link is invalid or has expired.';
  test.each([400, 404, 429, 500, 0])('failure status %i renders the same uniform text (no server detail)', async (status) => {
    verifyEmailToken.mockImplementation(() => Promise.reject(Object.assign(new Error('detail-' + status), { status })));
    const { container } = renderAt('/verify-email?token=t');
    await screen.findByText(EXPECTED);
    expect(container.textContent).not.toMatch(/detail-/);
    expect(screen.queryByText('Email verified')).toBeNull();
  });

  test('StrictMode double-effect does not spend the token twice', async () => {
    verifyEmailToken.mockResolvedValue({ verified: true });
    renderAt('/verify-email?token=once', true);
    await screen.findByText('Email verified');
    expect(verifyEmailToken).toHaveBeenCalledTimes(1);
  });
});
