// Task 20261007-email-verification: self-hiding "check your email" notice + resend cooldown.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor, fireEvent, act } from '@testing-library/react';

vi.mock('../lib/emailVerificationApi.js', () => ({
  getEmailStatus: vi.fn(), resendVerification: vi.fn(),
}));
import { getEmailStatus, resendVerification } from '../lib/emailVerificationApi.js';
import EmailVerifyNotice from './EmailVerifyNotice.jsx';

beforeEach(() => { getEmailStatus.mockReset(); resendVerification.mockReset(); });
afterEach(() => { cleanup(); vi.useRealTimers(); });

describe('EmailVerifyNotice', () => {
  test.each([
    ['flag off', { enabled: false, verified: false }],
    ['already verified', { enabled: true, verified: true }],
  ])('renders nothing when %s', async (_n, st) => {
    getEmailStatus.mockResolvedValue(st);
    const { container } = render(<EmailVerifyNotice />);
    await waitFor(() => expect(getEmailStatus).toHaveBeenCalled());
    await act(async () => {});
    expect(container.querySelector('[data-testid="email-verify-notice"]')).toBeNull();
  });

  test('renders nothing when the status check fails (fail quiet, server enforces)', async () => {
    getEmailStatus.mockRejectedValue(new Error('x'));
    const { container } = render(<EmailVerifyNotice />);
    await act(async () => {});
    expect(container.querySelector('[data-testid="email-verify-notice"]')).toBeNull();
  });

  test('unverified shows check-your-email with resend', async () => {
    getEmailStatus.mockResolvedValue({ enabled: true, verified: false });
    render(<EmailVerifyNotice />);
    expect(await screen.findByText('Check your email')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Resend verification email/ })).toBeEnabled();
  });

  test('affiliates context uses the creator-program copy', async () => {
    getEmailStatus.mockResolvedValue({ enabled: true, verified: false });
    render(<EmailVerifyNotice context="affiliates" />);
    expect(await screen.findByText('Verify your email to use the creator program')).toBeInTheDocument();
  });

  test('resend shows uniform message then disables with a cooldown countdown', async () => {
    getEmailStatus.mockResolvedValue({ enabled: true, verified: false, resend_cooldown_seconds: 45 });
    resendVerification.mockResolvedValue({ detail: 'ok', resend_cooldown_seconds: 30 });
    render(<EmailVerifyNotice />);
    fireEvent.click(await screen.findByRole('button', { name: /Resend verification email/ }));
    expect(await screen.findByText(/If a verification email is due/)).toBeInTheDocument();
    const btn = await screen.findByRole('button', { name: /Resend in 30s/ });
    expect(btn).toBeDisabled();
    expect(resendVerification).toHaveBeenCalledTimes(1);
    fireEvent.click(btn);
    expect(resendVerification).toHaveBeenCalledTimes(1);
  });

  test('cooldown counts down and re-enables the button', async () => {
    getEmailStatus.mockResolvedValue({ enabled: true, verified: false });
    resendVerification.mockResolvedValue({ detail: 'ok', resend_cooldown_seconds: 2 });
    render(<EmailVerifyNotice />);
    fireEvent.click(await screen.findByRole('button', { name: /Resend verification email/ }));
    expect(await screen.findByRole('button', { name: /Resend in 2s/ })).toBeDisabled();
    expect(await screen.findByRole('button', { name: /Resend in 1s/ }, { timeout: 2500 })).toBeDisabled();
    expect(await screen.findByRole('button', { name: /Resend verification email/ }, { timeout: 2500 })).toBeEnabled();
  });

  test('cooldown falls back to status value when resend omits it', async () => {
    getEmailStatus.mockResolvedValue({ enabled: true, verified: false, resend_cooldown_seconds: 45 });
    resendVerification.mockResolvedValue({ detail: 'ok' });
    render(<EmailVerifyNotice />);
    fireEvent.click(await screen.findByRole('button', { name: /Resend verification email/ }));
    expect(await screen.findByRole('button', { name: /Resend in 45s/ })).toBeDisabled();
  });

  test('429 shows a rate-limit warning, no cooldown lock, no success text', async () => {
    getEmailStatus.mockResolvedValue({ enabled: true, verified: false });
    resendVerification.mockRejectedValue(Object.assign(new Error('x'), { status: 429 }));
    render(<EmailVerifyNotice />);
    fireEvent.click(await screen.findByRole('button', { name: /Resend verification email/ }));
    expect(await screen.findByText(/Too many requests/)).toBeInTheDocument();
    expect(screen.queryByText(/If a verification email is due/)).toBeNull();
    expect(screen.getByRole('button', { name: /Resend verification email/ })).toBeEnabled();
  });

  test('other errors surface the client error message', async () => {
    getEmailStatus.mockResolvedValue({ enabled: true, verified: false });
    resendVerification.mockRejectedValue(Object.assign(new Error('Could not reach the server.'), { status: 0 }));
    render(<EmailVerifyNotice />);
    fireEvent.click(await screen.findByRole('button', { name: /Resend verification email/ }));
    expect(await screen.findByText('Could not reach the server.')).toBeInTheDocument();
  });

  test('re-checks status when emailKey changes (email change)', async () => {
    getEmailStatus.mockResolvedValueOnce({ enabled: true, verified: true });
    const { rerender, container } = render(<EmailVerifyNotice emailKey="a@x.com" />);
    await act(async () => {});
    expect(container.querySelector('[data-testid="email-verify-notice"]')).toBeNull();
    getEmailStatus.mockResolvedValueOnce({ enabled: true, verified: false });
    rerender(<EmailVerifyNotice emailKey="b@x.com" />);
    expect(await screen.findByText('Check your email')).toBeInTheDocument();
    expect(getEmailStatus).toHaveBeenCalledTimes(2);
  });
});
