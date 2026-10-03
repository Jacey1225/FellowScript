// Home announcements admin card (task 20261002-home-announcement-headline).
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor, fireEvent, within } from '@testing-library/react';
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom';

vi.mock('../lib/adminHomeMessagesApi.js', async () => {
  const actual = await vi.importActual('../lib/adminHomeMessagesApi.js');
  return {
    ...actual,
    listHomeMessages: vi.fn(), createHomeMessage: vi.fn(),
    setHomeMessageEnabled: vi.fn(), deleteHomeMessage: vi.fn(),
  };
});
import {
  listHomeMessages, createHomeMessage, setHomeMessageEnabled, deleteHomeMessage, AdminHomeMessagesApiError,
} from '../lib/adminHomeMessagesApi.js';
import AdminHomeMessages from './AdminHomeMessages.jsx';

function Where() { const l = useLocation(); return <div data-testid="where">{l.pathname}</div>; }
function renderCard() {
  return render(
    <MemoryRouter initialEntries={['/admin/accounts']}>
      <Routes>
        <Route path="/admin/accounts" element={<AdminHomeMessages />} />
        <Route path="*" element={<Where />} />
      </Routes>
    </MemoryRouter>,
  );
}
const msg = (id, text, enabled = false, priority = 0) => ({ id, text, enabled, priority, destination: 'none' });
const list = (items, extra = {}) => ({ items, text_max_length: 120, max_enabled: 2, ...extra });

beforeEach(() => {
  [listHomeMessages, createHomeMessage, setHomeMessageEnabled, deleteHomeMessage].forEach((f) => f.mockReset());
  listHomeMessages.mockResolvedValue(list([msg('a', 'Retreat signups open', true, 5), msg('b', 'Potluck <b>hi</b>')]));
});
afterEach(() => cleanup());

describe('AdminHomeMessages', () => {
  test('lists messages as plain text with status and counter', async () => {
    renderCard();
    expect(await screen.findByText('Retreat signups open')).toBeInTheDocument();
    // Markup in text is shown literally, never interpreted.
    expect(screen.getByText('Potluck <b>hi</b>')).toBeInTheDocument();
    expect(document.querySelector('li b')).toBeNull();
    expect(screen.getByText(/1 of 2 on/)).toBeInTheDocument();
    expect(screen.getByRole('list', { name: 'Home announcements' })).toBeInTheDocument();
  });

  test('empty state', async () => {
    listHomeMessages.mockResolvedValue(list([]));
    renderCard();
    expect(await screen.findByText('No announcements yet. Members see Welcome Back.')).toBeInTheDocument();
  });

  test('load error shows retry', async () => {
    listHomeMessages.mockRejectedValueOnce(new AdminHomeMessagesApiError('x', 500));
    renderCard();
    expect(await screen.findByText("Couldn't load announcements.")).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
    expect(await screen.findByText('Retreat signups open')).toBeInTheDocument();
  });

  test('401 and 403 navigate away', async () => {
    listHomeMessages.mockRejectedValueOnce(new AdminHomeMessagesApiError('x', 401));
    renderCard();
    expect(await screen.findByTestId('where')).toHaveTextContent('/signin');
    cleanup();
    listHomeMessages.mockRejectedValueOnce(new AdminHomeMessagesApiError('x', 403));
    renderCard();
    await waitFor(() => expect(screen.getByTestId('where')).toHaveTextContent('/'));
  });

  test('create is disabled when blank, then posts trimmed text with priority', async () => {
    createHomeMessage.mockResolvedValue(msg('c', 'New one'));
    renderCard();
    await screen.findByText('Retreat signups open');
    const add = screen.getByRole('button', { name: 'Add announcement' });
    expect(add).toBeDisabled();
    fireEvent.change(screen.getByLabelText('Announcement text'), { target: { value: '  New one ' } });
    fireEvent.change(screen.getByLabelText('Priority (higher shows first)'), { target: { value: '3' } });
    fireEvent.click(add);
    await waitFor(() => expect(createHomeMessage).toHaveBeenCalledWith({ text: 'New one', priority: 3 }));
    expect(await screen.findByText('Announcement added (off).')).toBeInTheDocument();
    expect(listHomeMessages).toHaveBeenCalledTimes(2);
  });

  test('client-side checks block links and angle brackets without calling the API', async () => {
    renderCard();
    await screen.findByText('Retreat signups open');
    fireEvent.change(screen.getByLabelText('Announcement text'), { target: { value: 'see https://x.com' } });
    fireEvent.click(screen.getByRole('button', { name: 'Add announcement' }));
    expect(await screen.findByText('Links are not allowed in announcements.')).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText('Announcement text'), { target: { value: 'a <b> c' } });
    fireEvent.click(screen.getByRole('button', { name: 'Add announcement' }));
    expect(await screen.findByText('Plain text only: no < or > characters.')).toBeInTheDocument();
    expect(createHomeMessage).not.toHaveBeenCalled();
  });

  test('server detail is surfaced on create failure', async () => {
    createHomeMessage.mockRejectedValue(new AdminHomeMessagesApiError('Message is too long', 422));
    renderCard();
    await screen.findByText('Retreat signups open');
    fireEvent.change(screen.getByLabelText('Announcement text'), { target: { value: 'Hello' } });
    fireEvent.click(screen.getByRole('button', { name: 'Add announcement' }));
    expect(await screen.findByText('Message is too long')).toBeInTheDocument();
  });

  test('toggle on calls PATCH and reloads', async () => {
    setHomeMessageEnabled.mockResolvedValue(msg('b', 'x', true));
    renderCard();
    await screen.findByText('Retreat signups open');
    fireEvent.click(screen.getByRole('switch', { name: 'Show "Potluck <b>hi</b>" on Home' }));
    await waitFor(() => expect(setHomeMessageEnabled).toHaveBeenCalledWith('b', true));
    expect(await screen.findByText('Announcement turned on.')).toBeInTheDocument();
  });

  test('at the cap, unselected switches are disabled with a hint', async () => {
    listHomeMessages.mockResolvedValue(list([msg('a', 'One', true), msg('b', 'Two', true), msg('c', 'Three')]));
    renderCard();
    await screen.findByText('Three');
    expect(screen.getByRole('switch', { name: 'Show "Three" on Home' })).toBeDisabled();
    expect(screen.getByRole('switch', { name: 'Show "One" on Home' })).not.toBeDisabled();
    expect(screen.getByText(/Turn one off to enable another\./)).toBeInTheDocument();
  });

  test('delete needs inline confirmation and can be cancelled', async () => {
    deleteHomeMessage.mockResolvedValue({ deleted: true });
    renderCard();
    await screen.findByText('Retreat signups open');
    const row = screen.getByTestId('home-msg-a');
    fireEvent.click(within(row).getByRole('button', { name: 'Delete' }));
    expect(deleteHomeMessage).not.toHaveBeenCalled();
    fireEvent.click(within(row).getByRole('button', { name: 'Cancel' }));
    expect(within(row).getByRole('button', { name: 'Delete' })).toBeInTheDocument();
    fireEvent.click(within(row).getByRole('button', { name: 'Delete' }));
    fireEvent.click(within(row).getByRole('button', { name: 'Confirm delete' }));
    await waitFor(() => expect(deleteHomeMessage).toHaveBeenCalledWith('a'));
    expect(await screen.findByText('Deleted.')).toBeInTheDocument();
  });
});
