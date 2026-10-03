// Task 20261002-shared-foundation step 9: hook/provider fail-closed behaviour.
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor, act } from '@testing-library/react';

let mockUser = { user_id: 'u1' };
vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => ({ user: mockUser }) }));
import { CapabilitiesProvider } from '../context/CapabilitiesContext.jsx';
import { useCapabilities } from './useCapabilities.js';

function Probe() {
  const c = useCapabilities();
  return <div data-testid="p">{JSON.stringify({ t: c.isEnabled('threads'), tc: c.termsCurrent })}</div>;
}
const mount = () => render(<CapabilitiesProvider><Probe /></CapabilitiesProvider>);
const body = { features: { threads: true }, links: {}, terms_current: false };
afterEach(() => { cleanup(); vi.restoreAllMocks(); mockUser = { user_id: 'u1' }; });

describe('useCapabilities', () => {
  test('outside a provider: everything off, terms current', () => {
    render(<Probe />);
    expect(screen.getByTestId('p').textContent).toBe('{"t":false,"tc":true}');
  });
  test('signed in: enabled after fetch', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ status: 200, json: async () => body }));
    mount();
    await waitFor(() => expect(screen.getByTestId('p').textContent).toBe('{"t":true,"tc":false}'));
  });
  test.each([
    ['404', () => Promise.resolve({ status: 404, json: async () => body })],
    ['500', () => Promise.resolve({ status: 500, json: async () => body })],
    ['network', () => Promise.reject(new TypeError('x'))],
    ['malformed', () => Promise.resolve({ status: 200, json: async () => ({ nope: 1 }) })],
  ])('%s -> off', async (_n, impl) => {
    const f = vi.fn(impl); vi.stubGlobal('fetch', f);
    mount();
    await waitFor(() => expect(f).toHaveBeenCalled());
    await new Promise((r) => setTimeout(r, 20));
    expect(screen.getByTestId('p').textContent).toBe('{"t":false,"tc":true}');
  });
  test('signed out: no fetch', async () => {
    mockUser = null;
    const f = vi.fn(); vi.stubGlobal('fetch', f);
    mount();
    await new Promise((r) => setTimeout(r, 20));
    expect(f).not.toHaveBeenCalled();
    expect(screen.getByTestId('p').textContent).toBe('{"t":false,"tc":true}');
  });
});

describe('failed first fetch is retried a bounded number of times (task 20261003-web-reader-ios-parity)', () => {
  test('network failure then success: features turn on without a refocus', async () => {
    vi.useFakeTimers();
    const f = vi.fn()
      .mockRejectedValueOnce(new TypeError('cold network'))
      .mockResolvedValue({ status: 200, json: async () => body });
    vi.stubGlobal('fetch', f);
    mount();
    await vi.advanceTimersByTimeAsync(0);
    expect(screen.getByTestId('p').textContent).toBe('{"t":false,"tc":true}');
    await act(async () => { await vi.advanceTimersByTimeAsync(3100); });
    expect(f).toHaveBeenCalledTimes(2);
    expect(screen.getByTestId('p').textContent).toBe('{"t":true,"tc":false}');
    vi.useRealTimers();
  });
  test('keeps failing: stops after two retries (no endless polling)', async () => {
    vi.useFakeTimers();
    const f = vi.fn().mockRejectedValue(new TypeError('down'));
    vi.stubGlobal('fetch', f);
    mount();
    await vi.advanceTimersByTimeAsync(60000);
    expect(f).toHaveBeenCalledTimes(3);
    vi.useRealTimers();
  });
  test('a real "all off" response is never retried', async () => {
    vi.useFakeTimers();
    const f = vi.fn().mockResolvedValue({ status: 200, json: async () => ({ features: {}, links: {}, terms_current: true }) });
    vi.stubGlobal('fetch', f);
    mount();
    await vi.advanceTimersByTimeAsync(60000);
    expect(f).toHaveBeenCalledTimes(1);
    vi.useRealTimers();
  });
});
