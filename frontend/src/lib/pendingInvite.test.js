// Task 20260929-group-invite-links testing: pending invite lives in
// sessionStorage only, expires after 24h, and only well-formed tokens stick.
import { describe, test, expect, beforeEach, afterEach, vi } from 'vitest';
import {
  setPendingInvite, getPendingInvite, clearPendingInvite, postAuthPath,
  PENDING_INVITE_TTL_MS, setGroupToOpen, takeGroupToOpen, peekGroupToOpen,
} from './pendingInvite.js';

const T1 = 'A'.repeat(43);
const T2 = 'B'.repeat(43);
// This Node env's jsdom may not expose localStorage; use a spy-able stand-in
// so "never localStorage" is asserted without depending on it.
const lsSet = vi.fn();
beforeEach(() => {
  sessionStorage.clear();
  lsSet.mockReset();
  vi.stubGlobal('localStorage', { setItem: lsSet, getItem: () => null, removeItem: () => {}, clear: () => {}, length: 0 });
});
afterEach(() => vi.unstubAllGlobals());

describe('pending invite', () => {
  test('stores in sessionStorage only, never localStorage', () => {
    setPendingInvite(T1);
    expect(getPendingInvite()).toBe(T1);
    expect(lsSet).not.toHaveBeenCalled();
  });

  test('ignores malformed tokens', () => {
    setPendingInvite('short');
    expect(getPendingInvite()).toBeNull();
  });

  test('newest link replaces the older one', () => {
    setPendingInvite(T1); setPendingInvite(T2);
    expect(getPendingInvite()).toBe(T2);
  });

  test('expires after 24h and is purged', () => {
    const now = 1_000_000;
    setPendingInvite(T1, now);
    expect(getPendingInvite(now + PENDING_INVITE_TTL_MS)).toBe(T1);
    expect(getPendingInvite(now + PENDING_INVITE_TTL_MS + 1)).toBeNull();
    expect(sessionStorage.getItem('fs_pending_invite')).toBeNull();
  });

  test('corrupt or tampered storage is discarded, not trusted', () => {
    sessionStorage.setItem('fs_pending_invite', '{not json');
    expect(getPendingInvite()).toBeNull();
    sessionStorage.setItem('fs_pending_invite', JSON.stringify({ token: '../../evil', at: Date.now() }));
    expect(getPendingInvite()).toBeNull();
    expect(sessionStorage.getItem('fs_pending_invite')).toBeNull();
  });

  test('clear removes it (consumed once)', () => {
    setPendingInvite(T1);
    clearPendingInvite();
    expect(getPendingInvite()).toBeNull();
  });

  test('postAuthPath resumes the join route, else the reader', () => {
    expect(postAuthPath()).toBe('/reader');
    setPendingInvite(T1);
    expect(postAuthPath()).toBe(`/join/${T1}`);
    clearPendingInvite();
    expect(postAuthPath()).toBe('/reader');
  });

  test('group-to-open is one-shot', () => {
    setGroupToOpen('g1');
    expect(peekGroupToOpen()).toBe('g1');
    expect(takeGroupToOpen()).toBe('g1');
    expect(takeGroupToOpen()).toBeNull();
  });
});
