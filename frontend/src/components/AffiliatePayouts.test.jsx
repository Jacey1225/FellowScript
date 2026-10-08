// Task 20261008-affiliate-payout-details: payouts section behavior.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor, fireEvent } from '@testing-library/react';

vi.mock('../lib/payoutsApi.js', async () => {
  const actual = await vi.importActual('../lib/payoutsApi.js');
  return { ...actual, getPayoutStatus: vi.fn(), requestPayoutCode: vi.fn(), verifyPayoutCode: vi.fn(), savePayoutDetails: vi.fn(), deletePayoutDetails: vi.fn() };
});
import * as api from '../lib/payoutsApi.js';
import AffiliatePayouts from './AffiliatePayouts.jsx';

const SET = { status: 'set', holder_name_masked: 'M. O.', account_type: 'checking', routing_last4: '0021', account_last4: '6789', updated_at: '2026-10-01T00:00:00Z' };
const change = (label, value) => fireEvent.change(screen.getByLabelText(label), { target: { value } });

beforeEach(() => { Object.values(api).forEach((f) => f.mockReset?.()); window.localStorage?.clear?.(); window.sessionStorage?.clear?.(); });
afterEach(() => cleanup());

async function toForm() {
  api.requestPayoutCode.mockResolvedValue({ password_required: false });
  api.verifyPayoutCode.mockResolvedValue({ proof: 'P1' });
  fireEvent.click(await screen.findByRole('button', { name: /Add details|Change details/ }));
  await screen.findByLabelText('Verification code');
  change('Verification code', '123456');
  fireEvent.click(screen.getByRole('button', { name: 'Verify' }));
  await screen.findByLabelText('Routing number');
}
function fill(over = {}) {
  change('Account holder name', over.holder ?? 'Mary Oneil');
  change('Routing number', over.routing ?? '021000021');
  change('Account number', over.acct ?? '123456789');
  change('Confirm account number', over.confirm ?? '123456789');
}

describe('AffiliatePayouts', () => {
  test.each([404, 403, 401])('renders nothing on %i', async (status) => {
    api.getPayoutStatus.mockRejectedValue(new api.PayoutsApiError('x', status));
    const { container } = render(<AffiliatePayouts />);
    await waitFor(() => expect(api.getPayoutStatus).toHaveBeenCalled());
    await waitFor(() => expect(container).toBeEmptyDOMElement());
  });

  test('server error shows retry', async () => {
    api.getPayoutStatus.mockRejectedValueOnce(new api.PayoutsApiError('x', 500));
    render(<AffiliatePayouts />);
    expect(await screen.findByText(/Couldn't load your payout details/)).toBeInTheDocument();
    api.getPayoutStatus.mockResolvedValue({ status: 'not_set' });
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
    expect(await screen.findByTestId('payout-empty')).toBeInTheDocument();
  });

  test('empty state offers Add and shows privacy copy; no Delete', async () => {
    api.getPayoutStatus.mockResolvedValue({ status: 'not_set' });
    render(<AffiliatePayouts />);
    expect(await screen.findByRole('button', { name: 'Add details' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Delete details' })).toBeNull();
    expect(screen.getByTestId('payout-privacy')).toHaveTextContent(/encrypted at rest/);
  });

  test('set state shows only masked summary', async () => {
    api.getPayoutStatus.mockResolvedValue(SET);
    render(<AffiliatePayouts />);
    const s = await screen.findByTestId('payout-summary');
    expect(s).toHaveTextContent('routing ending 0021');
    expect(s).toHaveTextContent('account ending 6789');
    expect(s.textContent).not.toMatch(/\d{5,}/);
    expect(screen.getByRole('button', { name: 'Change details' })).toBeInTheDocument();
  });

  test('re-auth gates the form; wrong code shows generic error and no form', async () => {
    api.getPayoutStatus.mockResolvedValue({ status: 'not_set' });
    api.requestPayoutCode.mockResolvedValue({ password_required: false });
    api.verifyPayoutCode.mockRejectedValue(new api.PayoutsApiError('reauth_failed', 403));
    render(<AffiliatePayouts />);
    fireEvent.click(await screen.findByRole('button', { name: 'Add details' }));
    expect(screen.queryByLabelText('Routing number')).toBeNull();
    await screen.findByLabelText('Verification code');
    change('Verification code', '000000');
    fireEvent.click(screen.getByRole('button', { name: 'Verify' }));
    expect(await screen.findByText(/not accepted/)).toBeInTheDocument();
    expect(screen.queryByLabelText('Routing number')).toBeNull();
  });

  test('password field required when server says so', async () => {
    api.getPayoutStatus.mockResolvedValue({ status: 'not_set' });
    api.requestPayoutCode.mockResolvedValue({ password_required: true });
    api.verifyPayoutCode.mockResolvedValue({ proof: 'P' });
    render(<AffiliatePayouts />);
    fireEvent.click(await screen.findByRole('button', { name: 'Add details' }));
    await screen.findByLabelText('Password');
    change('Verification code', '123456');
    expect(screen.getByRole('button', { name: 'Verify' })).toBeDisabled();
    change('Password', 'pw');
    expect(screen.getByRole('button', { name: 'Verify' })).toBeEnabled();
    fireEvent.click(screen.getByRole('button', { name: 'Verify' }));
    await waitFor(() => expect(api.verifyPayoutCode).toHaveBeenCalledWith('123456', 'pw'));
  });

  test('client validation blocks bad input; nothing sent', async () => {
    api.getPayoutStatus.mockResolvedValue({ status: 'not_set' });
    render(<AffiliatePayouts />);
    await toForm();
    fill({ routing: '123456789', confirm: '999999999' });
    fireEvent.click(screen.getByRole('button', { name: 'Save details' }));
    expect(await screen.findByText(/valid 9-digit routing/)).toBeInTheDocument();
    expect(screen.getByText(/do not match/)).toBeInTheDocument();
    expect(api.savePayoutDetails).not.toHaveBeenCalled();
  });

  test('successful save sends proof+fields (not confirm), shows masked result, clears values and storage', async () => {
    api.getPayoutStatus.mockResolvedValue({ status: 'not_set' });
    api.savePayoutDetails.mockResolvedValue(SET);
    const { container } = render(<AffiliatePayouts />);
    await toForm();
    fill({ holder: '  Mary Oneil ' });
    fireEvent.click(screen.getByRole('button', { name: 'Save details' }));
    expect(await screen.findByTestId('payout-summary')).toBeInTheDocument();
    expect(api.savePayoutDetails).toHaveBeenCalledWith('P1', {
      routing_number: '021000021', account_number: '123456789', account_type: 'checking', holder_name: 'Mary Oneil',
    });
    expect(container.innerHTML).not.toMatch(/021000021|123456789/);
    expect(JSON.stringify(window.localStorage ?? {}) + JSON.stringify(window.sessionStorage ?? {})).not.toMatch(/021000021|123456789|P1/);
  });

  test('failed save with reauth_required drops back to idle with form cleared; retry needs new verification', async () => {
    api.getPayoutStatus.mockResolvedValue({ status: 'not_set' });
    api.savePayoutDetails.mockRejectedValue(new api.PayoutsApiError('reauth_required', 403));
    const { container } = render(<AffiliatePayouts />);
    await toForm();
    fill();
    fireEvent.click(screen.getByRole('button', { name: 'Save details' }));
    expect(await screen.findByText(/verification expired/)).toBeInTheDocument();
    expect(screen.queryByLabelText('Routing number')).toBeNull();
    expect(container.innerHTML).not.toMatch(/123456789/);
  });

  test('cancel from form clears values', async () => {
    api.getPayoutStatus.mockResolvedValue({ status: 'not_set' });
    render(<AffiliatePayouts />);
    await toForm();
    fill();
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(await screen.findByRole('button', { name: 'Add details' })).toBeInTheDocument();
    api.requestPayoutCode.mockResolvedValue({}); 
    await toForm();
    expect(screen.getByLabelText('Routing number')).toHaveValue('');
    expect(screen.getByLabelText('Account number')).toHaveValue('');
  });

  test('delete requires re-auth then confirm; uses proof; returns to empty', async () => {
    api.getPayoutStatus.mockResolvedValue(SET);
    api.requestPayoutCode.mockResolvedValue({ password_required: false });
    api.verifyPayoutCode.mockResolvedValue({ proof: 'PD' });
    api.deletePayoutDetails.mockResolvedValue({});
    render(<AffiliatePayouts />);
    fireEvent.click(await screen.findByRole('button', { name: 'Delete details' }));
    await screen.findByLabelText('Verification code');
    expect(api.deletePayoutDetails).not.toHaveBeenCalled();
    change('Verification code', '123456');
    fireEvent.click(screen.getByRole('button', { name: 'Verify' }));
    await screen.findByText(/permanently removed/);
    expect(api.deletePayoutDetails).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }));
    await waitFor(() => expect(api.deletePayoutDetails).toHaveBeenCalledWith('PD'));
    expect(await screen.findByTestId('payout-empty')).toBeInTheDocument();
  });

  test('email send failure shows message and stays idle', async () => {
    api.getPayoutStatus.mockResolvedValue({ status: 'not_set' });
    api.requestPayoutCode.mockRejectedValue(new api.PayoutsApiError('email_failed', 502));
    render(<AffiliatePayouts />);
    fireEvent.click(await screen.findByRole('button', { name: 'Add details' }));
    expect(await screen.findByText(/couldn't send the code/)).toBeInTheDocument();
  });
});
