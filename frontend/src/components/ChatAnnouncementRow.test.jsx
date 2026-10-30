// Task 20261030-chat-announcements testing: timeline row + composer dialog.
// announcementsApi is mocked; GroupAnnouncementViewer/Form are light stubs.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react';

vi.mock('../lib/announcementsApi.js', async () => {
  const actual = await vi.importActual('../lib/announcementsApi.js');
  return { ...actual, fetchAnnouncement: vi.fn(), createAnnouncement: vi.fn(),
    rsvpJoin: vi.fn(), rsvpLeave: vi.fn(), pollVote: vi.fn(), pollRetract: vi.fn() };
});
vi.mock('./GroupAnnouncementViewer.jsx', () => ({
  default: ({ item, onBack, onRsvp }) => (
    <div data-testid="viewer" data-can-edit={String(item.can_edit)}>
      <span>{item.title}</span>
      <button onClick={onBack}>back</button>
      <button onClick={() => onRsvp(true)}>join</button>
    </div>
  ),
}));
vi.mock('./GroupAnnouncementForm.jsx', () => ({
  default: ({ onSubmit, onCancel, gateHit }) => (
    <div data-testid="form" data-gate={String(gateHit)}>
      <button onClick={() => onSubmit({ title: 'T', description: 'D' }).catch(() => {})}>submit</button>
      <button onClick={onCancel}>cancel</button>
    </div>
  ),
}));
import * as api from '../lib/announcementsApi.js';
import ChatAnnouncementRow from './ChatAnnouncementRow.jsx';
import ChatAnnouncementComposer from './ChatAnnouncementComposer.jsx';

const card = (o = {}) => ({ id: 'a1', title: 'Potluck', description: '', creator_username: 'ann',
  publish_at: '2026-10-30T10:00:00Z', edited: false, ...o });
const msg = (o = {}) => ({ id: 'm1', key: 'k1', mine: false, sender: 'ann', announcement: card(), ...o });
const row = (m = msg()) => render(<ChatAnnouncementRow message={m} userId="u1" groupId="g1" />);

beforeEach(() => { Object.values(api).forEach(f => f?.mockReset?.()); });
afterEach(cleanup);

describe('ChatAnnouncementRow', () => {
  test('shows the card title and poster meta; no fetch until tapped', () => {
    row();
    expect(screen.getByRole('button', { name: /Announcement: Potluck/ })).toBeTruthy();
    expect(screen.getByText('Posted by ann')).toBeTruthy();
    expect(api.fetchAnnouncement).not.toHaveBeenCalled();
  });
  test('own line says You; edited marker appears', () => {
    row(msg({ mine: true, announcement: card({ edited: true }) }));
    expect(screen.getByText('Posted by You · edited')).toBeTruthy();
  });
  test('tap fetches the full announcement and opens the viewer read-only (can_edit false)', async () => {
    api.fetchAnnouncement.mockResolvedValue({ id: 'a1', title: 'Potluck full', can_edit: true });
    row();
    fireEvent.click(screen.getByRole('button', { name: /Announcement: Potluck/ }));
    const viewer = await screen.findByTestId('viewer');
    expect(api.fetchAnnouncement).toHaveBeenCalledWith('u1', 'g1', 'a1');
    expect(viewer.getAttribute('data-can-edit')).toBe('false');
    expect(screen.getByRole('dialog', { name: 'Announcement' })).toBeTruthy();
    fireEvent.click(screen.getByText('back'));
    await waitFor(() => expect(screen.queryByTestId('viewer')).toBeNull());
  });
  test('RSVP routes through rsvpJoin and stays read-only', async () => {
    api.fetchAnnouncement.mockResolvedValue({ id: 'a1', title: 'P', can_edit: true });
    api.rsvpJoin.mockResolvedValue({ id: 'a1', title: 'P', can_edit: true, rsvp_count: 1 });
    row();
    fireEvent.click(screen.getByRole('button', { name: /Announcement: Potluck/ }));
    await screen.findByTestId('viewer');
    fireEvent.click(screen.getByText('join'));
    await waitFor(() => expect(api.rsvpJoin).toHaveBeenCalledWith('u1', 'g1', 'a1'));
    expect(screen.getByTestId('viewer').getAttribute('data-can-edit')).toBe('false');
  });
  test('failed fetch shows a warm alert, no viewer built from the card', async () => {
    api.fetchAnnouncement.mockRejectedValue(Object.assign(new Error('x'), { status: 500 }));
    row();
    fireEvent.click(screen.getByRole('button', { name: /Announcement: Potluck/ }));
    expect((await screen.findByRole('alert')).textContent).toBe("Couldn't open that announcement. Please try again.");
    expect(screen.queryByTestId('viewer')).toBeNull();
  });
  test('404 shows the no-longer-available copy', async () => {
    api.fetchAnnouncement.mockRejectedValue(Object.assign(new Error('gone'), { status: 404 }));
    row();
    fireEvent.click(screen.getByRole('button', { name: /Announcement: Potluck/ }));
    expect((await screen.findByRole('alert')).textContent).toBe('That announcement is no longer available.');
  });
  test('a retry after failure can succeed and clears the error', async () => {
    api.fetchAnnouncement.mockRejectedValueOnce(Object.assign(new Error('x'), { status: 500 }))
      .mockResolvedValueOnce({ id: 'a1', title: 'P', can_edit: false });
    row();
    const btn = screen.getByRole('button', { name: /Announcement: Potluck/ });
    fireEvent.click(btn);
    await screen.findByRole('alert');
    fireEvent.click(btn);
    await screen.findByTestId('viewer');
    expect(screen.queryByRole('alert')).toBeNull();
  });
});

describe('ChatAnnouncementComposer', () => {
  test('submit creates with post_to_chat true and closes', async () => {
    api.createAnnouncement.mockResolvedValue({ id: 'new' });
    const onClose = vi.fn();
    render(<ChatAnnouncementComposer userId="u1" groupId="g1" onClose={onClose} />);
    expect(screen.getByRole('dialog', { name: 'New announcement' })).toBeTruthy();
    fireEvent.click(screen.getByText('submit'));
    await waitFor(() => expect(onClose).toHaveBeenCalled());
    expect(api.createAnnouncement).toHaveBeenCalledWith('u1', 'g1', { title: 'T', description: 'D', post_to_chat: true });
  });
  test('failure keeps the form open (no close)', async () => {
    api.createAnnouncement.mockRejectedValue(Object.assign(new Error('nope'), { status: 500 }));
    const onClose = vi.fn();
    render(<ChatAnnouncementComposer userId="u1" groupId="g1" onClose={onClose} />);
    fireEvent.click(screen.getByText('submit'));
    await waitFor(() => expect(api.createAnnouncement).toHaveBeenCalled());
    expect(onClose).not.toHaveBeenCalled();
    expect(screen.getByTestId('form')).toBeTruthy();
  });
  test('free-limit 403 flips the gate state', async () => {
    api.createAnnouncement.mockRejectedValue(Object.assign(new Error('x'), { status: 403, gate: { limit: 1 } }));
    render(<ChatAnnouncementComposer userId="u1" groupId="g1" onClose={vi.fn()} />);
    fireEvent.click(screen.getByText('submit'));
    await waitFor(() => expect(screen.getByTestId('form').getAttribute('data-gate')).toBe('true'));
  });
  test('cancel closes', () => {
    const onClose = vi.fn();
    render(<ChatAnnouncementComposer userId="u1" groupId="g1" onClose={onClose} />);
    fireEvent.click(screen.getByText('cancel'));
    expect(onClose).toHaveBeenCalled();
  });
});
