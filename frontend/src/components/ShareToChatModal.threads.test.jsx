import React from 'react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react';

vi.mock('../lib/threadShare.js', async (orig) => ({ ...(await orig()), loadShareThreads: vi.fn() }));
import { loadShareThreads } from '../lib/threadShare.js';
import ShareToChatModal from './ShareToChatModal.jsx';

const groups = { g1: { title: 'Study', users: ['a'] } };
const mount = (props = {}) => {
  const onSend = vi.fn().mockResolvedValue();
  render(<ShareToChatModal open onClose={() => {}} preview={<i>p</i>} friends={[]} groups={groups}
    loaded onSend={onSend} userId="u" threadsEnabled {...props} />);
  return onSend;
};

describe('ShareToChatModal thread destinations', () => {
  beforeEach(() => { loadShareThreads.mockReset(); });
  afterEach(() => { cleanup(); });

  it('sends to the picked thread', async () => {
    loadShareThreads.mockResolvedValue([{ id: 't1', title: 'Romans talk' }]);
    const onSend = mount();
    fireEvent.click(screen.getByRole('radio', { name: /Study, group/ }));
    fireEvent.click(await screen.findByRole('radio', { name: /Thread Romans talk/ }));
    fireEvent.click(screen.getByRole('button', { name: 'Send' }));
    await waitFor(() => expect(onSend).toHaveBeenCalled());
    expect(onSend.mock.calls[0][0].id).toBe('g1');
    expect(onSend.mock.calls[0][1]).toEqual({ id: 't1', title: 'Romans talk' });
  });

  it('defaults to the main chat (no thread)', async () => {
    loadShareThreads.mockResolvedValue([{ id: 't1', title: 'x' }]);
    const onSend = mount();
    fireEvent.click(screen.getByRole('radio', { name: /Study, group/ }));
    await screen.findByRole('radio', { name: /Group chat/ });
    fireEvent.click(screen.getByRole('button', { name: 'Send' }));
    await waitFor(() => expect(onSend).toHaveBeenCalled());
    expect(onSend.mock.calls[0][1]).toBeNull();
  });

  it('shows a retry line and no fabricated list when loading fails', async () => {
    loadShareThreads.mockImplementation(async () => { throw new Error('x'); });
    mount();
    fireEvent.click(screen.getByRole('radio', { name: /Study, group/ }));
    expect(await screen.findByText(/Couldn't load threads/)).toBeTruthy();
    expect(screen.queryByRole('radio', { name: /Thread / })).toBeNull();
  });

  it('offers no threads with the flags off', () => {
    mount({ threadsEnabled: false });
    fireEvent.click(screen.getByRole('radio', { name: /Study, group/ }));
    expect(loadShareThreads).not.toHaveBeenCalled();
  });
});
