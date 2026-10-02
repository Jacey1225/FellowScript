// Admin listing-moderation page: queue, approve, reject-with-reason, hide, restore.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor, fireEvent, within } from '@testing-library/react';
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom';

const mockAuth = { user: { user_id: 'a1' } };
vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => mockAuth }));
vi.mock('../components/AppNav.jsx', () => ({ default: () => null }));
vi.mock('../lib/adminListingsApi.js', async () => {
  const actual = await vi.importActual('../lib/adminListingsApi.js');
  return {
    ...actual, fetchQueue: vi.fn(), approveListing: vi.fn(), rejectListing: vi.fn(),
    hideListing: vi.fn(), restoreListing: vi.fn(), removeListing: vi.fn(),
  };
});
import {
  fetchQueue, approveListing, rejectListing, hideListing, restoreListing, removeListing, AdminListingsApiError,
} from '../lib/adminListingsApi.js';
import AdminListings from './AdminListings.jsx';

function Where() { const l = useLocation(); return <div data-testid="where">{l.pathname}</div>; }
function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/admin/listings']}>
      <Routes>
        <Route path="/admin/listings" element={<AdminListings />} />
        <Route path="*" element={<Where />} />
      </Routes>
    </MemoryRouter>,
  );
}
const ITEM = {
  public_id: 'abc1234567', status: 'pending_review', title: 'Young Adults Bible Study', summary: 'Weekly study.',
  description_text: 'We meet Tuesdays.', church_name: 'Grace Church', city: 'Austin', region: 'TX', country: 'US',
  hidden_reason_code: null, reject_reason_code: null, open_reports: 2, group_id: 'g1', owner_id: 'o1',
};

beforeEach(() => {
  [fetchQueue, approveListing, rejectListing, hideListing, restoreListing, removeListing].forEach((f) => f.mockReset());
  fetchQueue.mockResolvedValue({ items: [ITEM] });
});
afterEach(() => cleanup());

describe('AdminListings', () => {
  test('shows the pending queue with details and report count', async () => {
    renderPage();
    expect(await screen.findByText('Young Adults Bible Study')).toBeInTheDocument();
    expect(screen.getByText(/Grace Church · Austin, TX, US · 2 open reports/)).toBeInTheDocument();
    expect(screen.getByText('We meet Tuesdays.')).toBeInTheDocument();
    expect(fetchQueue).toHaveBeenCalledWith('pending_review');
  });

  test('approve calls the API and reloads', async () => {
    approveListing.mockResolvedValue({});
    renderPage();
    fireEvent.click(await screen.findByRole('button', { name: 'Approve' }));
    await waitFor(() => expect(approveListing).toHaveBeenCalledWith('abc1234567'));
    await waitFor(() => expect(fetchQueue).toHaveBeenCalledTimes(2));
  });

  test('reject needs a reason step, then sends the chosen code', async () => {
    rejectListing.mockResolvedValue({});
    renderPage();
    const card = await screen.findByTestId('listing-abc1234567');
    fireEvent.click(within(card).getByRole('button', { name: 'Reject' }));
    expect(rejectListing).not.toHaveBeenCalled();
    const buttons = within(card).getAllByRole('button', { name: 'Reject' });
    fireEvent.click(buttons[buttons.length - 1]);
    await waitFor(() => expect(rejectListing).toHaveBeenCalledWith('abc1234567', 'inappropriate'));
  });

  test('empty queue shows the empty copy', async () => {
    fetchQueue.mockResolvedValue({ items: [] });
    renderPage();
    expect(await screen.findByText('Nothing is waiting for review.')).toBeInTheDocument();
  });

  test('hidden tab offers Restore', async () => {
    fetchQueue.mockImplementation(async (s) => ({ items: s === 'hidden' ? [{ ...ITEM, status: 'hidden', hidden_reason_code: 'reported' }] : [] }));
    restoreListing.mockResolvedValue({});
    renderPage();
    fireEvent.click(await screen.findByText('Hidden'));
    fireEvent.click(await screen.findByRole('button', { name: 'Restore' }));
    await waitFor(() => expect(restoreListing).toHaveBeenCalledWith('abc1234567'));
  });

  test('403 sends a non-admin home; API errors are shown, not swallowed', async () => {
    fetchQueue.mockRejectedValueOnce(new AdminListingsApiError('Forbidden', 403));
    renderPage();
    expect(await screen.findByTestId('where')).toHaveTextContent('/');
    cleanup();
    fetchQueue.mockRejectedValueOnce(new AdminListingsApiError('Boom', 500));
    renderPage();
    expect(await screen.findByText('Boom')).toBeInTheDocument();
  });
});
