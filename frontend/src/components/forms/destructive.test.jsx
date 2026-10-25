import React from 'react';
import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest';
import { render, screen, fireEvent, cleanup, act } from '@testing-library/react';
import { useUndoDelete } from './useUndoDelete.jsx';
import { DeleteAccountDialog } from './DeleteAccountDialog.jsx';

afterEach(() => { cleanup(); vi.useRealTimers(); vi.restoreAllMocks(); });

function Harness({ hide, restore, commit }) {
  const u = useUndoDelete();
  return (<div><button onClick={() => u.schedule({ message: 'Gone.', hide, restore, commit })}>del</button>{u.snackbar}</div>);
}

describe('useUndoDelete (tier 1)', () => {
  beforeEach(() => vi.useFakeTimers());
  it('commits only after 6 seconds', () => {
    const hide = vi.fn(), restore = vi.fn(), commit = vi.fn();
    render(<Harness hide={hide} restore={restore} commit={commit} />);
    fireEvent.click(screen.getByText('del'));
    expect(hide).toHaveBeenCalled(); expect(commit).not.toHaveBeenCalled();
    act(() => { vi.advanceTimersByTime(5900); });
    expect(commit).not.toHaveBeenCalled();
    act(() => { vi.advanceTimersByTime(200); });
    expect(commit).toHaveBeenCalledTimes(1);
  });
  it('Undo restores and never commits', () => {
    const hide = vi.fn(), restore = vi.fn(), commit = vi.fn();
    render(<Harness hide={hide} restore={restore} commit={commit} />);
    fireEvent.click(screen.getByText('del'));
    fireEvent.click(screen.getByText('Undo'));
    act(() => { vi.advanceTimersByTime(7000); });
    expect(restore).toHaveBeenCalled(); expect(commit).not.toHaveBeenCalled();
  });
});

describe('DeleteAccountDialog (tier 3 + re-auth)', () => {
  const props = { open: true, username: 'jacob', userId: 'u1', onClose: vi.fn(), onDeleted: vi.fn(), onError: vi.fn() };
  it('keeps the destructive action inert until the username matches', () => {
    render(<DeleteAccountDialog {...props} />);
    const btn = screen.getByRole('button', { name: 'Delete my account' });
    expect(btn).toHaveAttribute('aria-disabled', 'true');
    fireEvent.click(btn);
    expect(screen.queryByLabelText(/Current password/)).toBeNull();
    fireEvent.change(screen.getByLabelText(/Type your username/), { target: { value: 'JACOB' } });
    fireEvent.click(screen.getByRole('button', { name: 'Delete my account' }));
    expect(screen.getByLabelText(/Current password/)).toBeInTheDocument();
  });
  it('does not call DELETE when the password check fails', async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: false, status: 401, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);
    render(<DeleteAccountDialog {...props} />);
    fireEvent.change(screen.getByLabelText(/Type your username/), { target: { value: 'jacob' } });
    fireEvent.click(screen.getByRole('button', { name: 'Delete my account' }));
    fireEvent.change(screen.getByLabelText(/Current password/), { target: { value: 'wrong' } });
    await act(async () => { fireEvent.submit(screen.getByLabelText(/Current password/).closest('form')); });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][1].method).toBe('POST');
    expect(await screen.findByText('That password did not match.')).toBeInTheDocument();
    expect(props.onDeleted).not.toHaveBeenCalled();
    vi.unstubAllGlobals();
  });
});
