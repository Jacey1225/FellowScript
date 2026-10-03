// Task 20261003-web-reader-ios-parity step 1: updateSession shows the shared
// upgrade modal on a plan block (same as create) and a plain toast otherwise.
// Run: npm test -- --run src/hooks/useSessions.update.test.js
import { describe, test, expect, vi, beforeEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useSessions } from './useSessions.js';
import * as upgrade from '../lib/upgradePrompt.js';

const USER = { user_id: 'user-1' };
beforeEach(() => { global.fetch = vi.fn(); upgrade.dismissUpgradePrompt(); });

function setup() {
  const wsRef = { current: { readyState: 0, send: vi.fn() } };
  return renderHook(() => useSessions({ user: USER, wsRef, currentContact: null }));
}
const body = { title: 't', timeStart: new Date().toISOString(), verses: [] };

describe('updateSession plan block', () => {
  test('a sessions plan block opens the upgrade modal and returns false', async () => {
    global.fetch = vi.fn().mockResolvedValue({
      ok: false, status: 403,
      json: async () => ({ resource: 'sessions', allowed: false, used: 1, limit: 1 }),
    });
    const { result } = setup();
    let ok;
    await act(async () => { ok = await result.current.updateSession('s1', body); });
    expect(ok).toBe(false);
    expect(upgrade.getUpgradePrompt()?.info).toMatchObject({ resource: 'sessions' });
  });
  test('an ordinary failure does not open the modal', async () => {
    global.fetch = vi.fn().mockResolvedValue({ ok: false, status: 500, json: async () => ({}) });
    const { result } = setup();
    let ok;
    await act(async () => { ok = await result.current.updateSession('s1', body); });
    expect(ok).toBe(false);
    expect(upgrade.getUpgradePrompt()).toBeNull();
  });
});
