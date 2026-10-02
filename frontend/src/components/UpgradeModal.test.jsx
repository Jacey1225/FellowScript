import React from 'react';
import { describe, test, expect, afterEach, vi } from 'vitest';
import { render, screen, fireEvent, cleanup, act, waitFor } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import UpgradeModal from './UpgradeModal.jsx';
import { showUpgradePrompt, dismissUpgradePrompt, getUpgradePrompt } from '../lib/upgradePrompt.js';

afterEach(() => { act(() => dismissUpgradePrompt()); cleanup(); });

const setup = (path = '/reader') => render(
  <MemoryRouter initialEntries={[path]}>
    <UpgradeModal />
    <Routes>
      <Route path="/reader" element={<div>reader page</div>} />
      <Route path="/account" element={<div id="subscription" tabIndex={-1}>account page</div>} />
    </Routes>
  </MemoryRouter>,
);

describe('UpgradeModal', () => {
  test('renders nothing until a block is shown', () => {
    setup();
    expect(screen.queryByText('Not available on the Free plan')).toBeNull();
  });

  test('shows title, resource copy, Subscribe and dismiss', async () => {
    setup();
    act(() => showUpgradePrompt({ resource: 'notes', limit: 5, used: 5, paidOnly: false }));
    expect(await screen.findByText('Not available on the Free plan')).toBeInTheDocument();
    expect(screen.getByText(/Free plan includes 5 notes per week/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Subscribe' })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Not now' }));
    expect(getUpgradePrompt()).toBeNull();
  });

  test('Subscribe dismisses and routes to the Account page', async () => {
    Element.prototype.scrollIntoView = vi.fn();
    setup('/reader');
    act(() => showUpgradePrompt({ resource: 'explorer_publish', paidOnly: true, limit: null, used: null }));
    fireEvent.click(await screen.findByRole('button', { name: 'Subscribe' }));
    expect(await screen.findByText('account page')).toBeInTheDocument();
    await waitFor(() => expect(Element.prototype.scrollIntoView).toHaveBeenCalled());
  });
});
