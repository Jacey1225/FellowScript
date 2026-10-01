// Task 20261001-promo-owner-rewards testing: admin creator-code page.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor, fireEvent } from '@testing-library/react';
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom';

const mockAuth = { user: { user_id: 'u1' } };
vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => mockAuth }));
vi.mock('../components/AppNav.jsx', () => ({ default: () => null }));
vi.mock('../lib/ownerRewardsApi.js', async () => {
  const actual = await vi.importActual('../lib/ownerRewardsApi.js');
  return { ...actual, createCreatorCode: vi.fn(), listCodesOverview: vi.fn(), deactivateCode: vi.fn() };
});
import { createCreatorCode, listCodesOverview, deactivateCode, OwnerRewardsApiError } from '../lib/ownerRewardsApi.js';
import AdminPromoCodes from './AdminPromoCodes.jsx';

function Where() { const l = useLocation(); return <div data-testid="where">{l.pathname}</div>; }
function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/admin/promo']}>
      <Routes>
        <Route path="/admin/promo" element={<AdminPromoCodes />} />
        <Route path="*" element={<Where />} />
      </Routes>
    </MemoryRouter>,
  );
}
const ROW = {
  id: 'c1', code: 'CREATOR1', kind: 'creator', owner_email: 'own@x.co', creator_name: 'Cee',
  redemption_count: 3, max_redemptions: 10, rewards_earned: 2, rewards_claimed: 1, active: true,
};

beforeEach(() => {
  createCreatorCode.mockReset(); listCodesOverview.mockReset(); deactivateCode.mockReset();
});
afterEach(() => cleanup());

describe('AdminPromoCodes', () => {
  test('lists codes with email, redemption and reward counts', async () => {
    listCodesOverview.mockResolvedValue([ROW]);
    renderPage();
    expect(await screen.findByText('CREATOR1')).toBeInTheDocument();
    expect(screen.getByText('own@x.co')).toBeInTheDocument();
    expect(screen.getByText('3 / 10')).toBeInTheDocument();
    expect(screen.getByText('2 / 1')).toBeInTheDocument();
    expect(screen.getByText('Active')).toBeInTheDocument();
  });

  test('empty list shows placeholder', async () => {
    listCodesOverview.mockResolvedValue([]);
    renderPage();
    expect(await screen.findByText('No codes yet.')).toBeInTheDocument();
  });

  test('401 redirects to signin, 403 to home', async () => {
    listCodesOverview.mockRejectedValue(new OwnerRewardsApiError('x', 401));
    renderPage();
    await waitFor(() => expect(screen.getByTestId('where').textContent).toBe('/signin'));
    cleanup();
    listCodesOverview.mockRejectedValue(new OwnerRewardsApiError('x', 403));
    renderPage();
    await waitFor(() => expect(screen.getByTestId('where').textContent).toBe('/'));
  });

  test('404 (flag off) shows neutral notice and no form', async () => {
    listCodesOverview.mockRejectedValue(new OwnerRewardsApiError('x', 404));
    renderPage();
    expect(await screen.findByText(/aren't enabled/)).toBeInTheDocument();
    expect(screen.queryByLabelText('Create creator code')).toBeNull();
  });

  test('other load error shown inline', async () => {
    listCodesOverview.mockRejectedValue(new OwnerRewardsApiError('boom', 500));
    renderPage();
    expect(await screen.findByText('boom')).toBeInTheDocument();
  });

  test('create validates name and email client-side without calling the API', async () => {
    listCodesOverview.mockResolvedValue([]);
    renderPage();
    await screen.findByText('No codes yet.');
    fireEvent.click(screen.getByText('Create code'));
    expect(await screen.findByText('Enter a creator name.')).toBeInTheDocument();
    fireEvent.change(document.getElementById('cc-name'), { target: { value: 'Cee' } });
    fireEvent.change(document.getElementById('cc-email'), { target: { value: 'not-an-email' } });
    // fireEvent.submit bypasses native type=email validation so the JS check is exercised
    fireEvent.submit(screen.getByLabelText('Create creator code'));
    expect(await screen.findByText('Enter a valid owner email.')).toBeInTheDocument();
    expect(createCreatorCode).not.toHaveBeenCalled();
  });

  test('create submits trimmed values, shows server-generated code, reloads list', async () => {
    listCodesOverview.mockResolvedValue([]);
    createCreatorCode.mockResolvedValue({ creator: {}, code: { code: 'SECRET123' } });
    renderPage();
    await screen.findByText('No codes yet.');
    fireEvent.change(document.getElementById('cc-name'), { target: { value: '  Cee  ' } });
    fireEvent.change(document.getElementById('cc-email'), { target: { value: ' own@x.co ' } });
    fireEvent.click(screen.getByText('Create code'));
    expect((await screen.findByTestId('created-code')).textContent).toBe('SECRET123');
    expect(createCreatorCode).toHaveBeenCalledWith(expect.objectContaining({ name: 'Cee', ownerEmail: 'own@x.co' }));
    // no client-supplied code: server generates
    expect(createCreatorCode.mock.calls[0][0].code).toBeUndefined();
    expect(listCodesOverview.mock.calls.length).toBeGreaterThanOrEqual(2);
  });

  test('create server error is displayed and no code shown', async () => {
    listCodesOverview.mockResolvedValue([]);
    createCreatorCode.mockRejectedValue(new OwnerRewardsApiError('Email already used', 409));
    renderPage();
    await screen.findByText('No codes yet.');
    fireEvent.change(document.getElementById('cc-name'), { target: { value: 'Cee' } });
    fireEvent.change(document.getElementById('cc-email'), { target: { value: 'own@x.co' } });
    fireEvent.click(screen.getByText('Create code'));
    expect(await screen.findByText('Email already used')).toBeInTheDocument();
    expect(screen.queryByTestId('created-code')).toBeNull();
  });

  test('deactivate calls API for the row and reloads; inactive rows have no button', async () => {
    listCodesOverview.mockResolvedValueOnce([ROW, { ...ROW, id: 'c2', code: 'OLD', active: false }]);
    listCodesOverview.mockResolvedValue([{ ...ROW, active: false }]);
    deactivateCode.mockResolvedValue({});
    renderPage();
    await screen.findByText('CREATOR1');
    expect(screen.getAllByText('Deactivate')).toHaveLength(1);
    fireEvent.click(screen.getByLabelText('Deactivate CREATOR1'));
    await waitFor(() => expect(deactivateCode).toHaveBeenCalledWith('c1'));
    await waitFor(() => expect(screen.queryByText('Deactivate')).toBeNull());
  });

  test('kind filter reloads with kind', async () => {
    listCodesOverview.mockResolvedValue([]);
    renderPage();
    await screen.findByText('No codes yet.');
    expect(listCodesOverview).toHaveBeenCalledWith({ kind: undefined });
  });
});
