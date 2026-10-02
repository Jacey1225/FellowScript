import { describe, test, expect, vi, beforeEach } from 'vitest';
import {
  blockedFromBody, blockedFromResponse, upgradeBody, showUpgradePrompt,
  dismissUpgradePrompt, getUpgradePrompt, handleBlockedResponse,
} from './upgradePrompt.js';

beforeEach(() => dismissUpgradePrompt());

const body = (over = {}) => ({ resource: 'notes', allowed: false, unlimited: false, used: 5, limit: 5, remaining: 0, ...over });

describe('blockedFromBody', () => {
  test('detects a bare body and a detail-nested body', () => {
    expect(blockedFromBody(403, body())).toEqual({ resource: 'notes', paidOnly: false, used: 5, limit: 5 });
    expect(blockedFromBody(403, { detail: body({ resource: 'sessions', limit: 1, used: 1 }) }).resource).toBe('sessions');
  });
  test('paid_only flag is carried', () => {
    expect(blockedFromBody(403, body({ resource: 'explorer_publish', paid_only: true })).paidOnly).toBe(true);
  });
  test('ignores other statuses, unknown resources, allowed:true and permission 403s', () => {
    expect(blockedFromBody(402, body())).toBeNull();
    expect(blockedFromBody(403, body({ resource: 'note_chars' }))).toBeNull();
    expect(blockedFromBody(403, body({ allowed: true }))).toBeNull();
    expect(blockedFromBody(403, { detail: 'Forbidden' })).toBeNull();
    expect(blockedFromBody(403, null)).toBeNull();
  });
});

describe('blockedFromResponse / handleBlockedResponse', () => {
  test('shows the prompt for a plan block and not for others', async () => {
    const res = { status: 403, json: async () => ({ detail: body({ resource: 'session_summaries', paid_only: true }) }) };
    expect(await handleBlockedResponse(res)).toBe(true);
    expect(getUpgradePrompt().info.resource).toBe('session_summaries');
    dismissUpgradePrompt();
    expect(await handleBlockedResponse({ status: 403, json: async () => ({ detail: 'nope' }) })).toBe(false);
    expect(getUpgradePrompt()).toBeNull();
    expect(await blockedFromResponse({ status: 500, json: vi.fn() })).toBeNull();
    expect(await blockedFromResponse({ status: 403, json: async () => { throw new Error('x'); } })).toBeNull();
  });
  test('latest block replaces the previous (single instance)', () => {
    showUpgradePrompt({ resource: 'notes', limit: 5 });
    showUpgradePrompt({ resource: 'sessions', limit: 1 });
    expect(getUpgradePrompt().info.resource).toBe('sessions');
  });
});

describe('upgradeBody copy', () => {
  test('interpolates limits and never hardcodes them', () => {
    expect(upgradeBody({ resource: 'notes', limit: 7 })).toContain('7 notes per week');
    expect(upgradeBody({ resource: 'agent_events', limit: 1 })).toContain('1 scheduled devotion.');
    expect(upgradeBody({ resource: 'sessions', limit: 1 })).toContain('1 session at a time');
    expect(upgradeBody({ resource: 'session_summaries' })).toMatch(/subscribers/);
    expect(upgradeBody({ resource: 'explorer_publish' })).toMatch(/Browsing and joining stay free/);
    expect(upgradeBody({ resource: 'notes' })).not.toMatch(/\d/);
  });
});

describe('flow integration', () => {
  test('explorerApi request attaches the blocked info to a 403 plan block', async () => {
    const { request } = await import('./explorerApi.js');
    global.fetch = vi.fn().mockResolvedValue({
      ok: false, status: 403, headers: { get: () => null },
      json: async () => ({ detail: { resource: 'explorer_publish', allowed: false, unlimited: false, used: 0, limit: 0, remaining: 0, paid_only: true } }),
    });
    await expect(request('/explorer/u/groups/g/listing/submit', { method: 'POST' }, 'fallback')).rejects.toMatchObject({
      status: 403, blocked: { resource: 'explorer_publish', paidOnly: true },
    });
  });
});
