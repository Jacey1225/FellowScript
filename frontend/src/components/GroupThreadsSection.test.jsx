// Task 20261001-message-threads step 9: Threads section in the group info panel.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, waitFor } from '@testing-library/react';

vi.mock('../lib/threadsApi.js', async (orig) => ({ ...(await orig()), listThreads: vi.fn() }));
import { listThreads } from '../lib/threadsApi.js';
import GroupThreadsSection, { _clearThreadsCache, threadRowLabel } from './GroupThreadsSection.jsx';
import { getVisibleGroupInfoSections, GROUP_INFO_SECTIONS } from './groupInfoSections.js';

const T = (id, over = {}) => ({ id, title: `Title ${id}`, root_preview: `preview ${id}`, reply_count: 2, last_activity_at: new Date().toISOString(), root_deleted: false, ...over });
const page = (threads, cursor = null) => ({ threads, hasMore: !!cursor, cursor });

beforeEach(() => { _clearThreadsCache(); listThreads.mockReset(); vi.spyOn(console, 'error').mockImplementation(() => {}); });
afterEach(() => { cleanup(); vi.restoreAllMocks(); });

describe('section', () => {
  test('lists threads and opens one on tap', async () => {
    listThreads.mockResolvedValue(page([T('t1'), T('t2', { reply_count: 1 })]));
    const onOpenThread = vi.fn();
    render(<GroupThreadsSection userId="u1" groupId="g1" onOpenThread={onOpenThread} />);
    const row = await screen.findByRole('button', { name: /Title t1, 2 replies/ });
    expect(screen.getByRole('button', { name: /Title t2, 1 reply,/ })).toBeInTheDocument();
    fireEvent.click(row);
    expect(onOpenThread).toHaveBeenCalledWith(expect.objectContaining({ id: 't1' }));
  });
  test('deleted root shows Original message deleted', async () => {
    listThreads.mockResolvedValue(page([T('t1', { root_deleted: true, root_preview: 'secret' })]));
    render(<GroupThreadsSection userId="u1" groupId="g1" onOpenThread={vi.fn()} />);
    expect(await screen.findByText('Original message deleted')).toBeInTheDocument();
    expect(screen.queryByText('secret')).toBeNull();
  });
  test('empty state', async () => {
    listThreads.mockResolvedValue(page([]));
    render(<GroupThreadsSection userId="u1" groupId="g1" onOpenThread={vi.fn()} />);
    expect(await screen.findByText(/No threads yet/)).toBeInTheDocument();
  });
  test('Show more pages with the cursor and dedups', async () => {
    listThreads.mockResolvedValueOnce(page([T('t1')], { timestamp: 'x', id: 't1' }));
    listThreads.mockResolvedValueOnce(page([T('t1'), T('t2')]));
    render(<GroupThreadsSection userId="u1" groupId="g1" onOpenThread={vi.fn()} />);
    fireEvent.click(await screen.findByRole('button', { name: 'Show more' }));
    await screen.findByRole('button', { name: /Title t2/ });
    expect(listThreads).toHaveBeenLastCalledWith('u1', 'g1', { timestamp: 'x', id: 't1' });
    expect(screen.getAllByRole('button', { name: /Title t1/ })).toHaveLength(1);
    expect(screen.queryByRole('button', { name: 'Show more' })).toBeNull();
  });
  test('error shows Retry and Retry recovers', async () => {
    listThreads.mockRejectedValueOnce(new Error('x'));
    listThreads.mockResolvedValueOnce(page([T('t1')]));
    render(<GroupThreadsSection userId="u1" groupId="g1" onOpenThread={vi.fn()} />);
    expect(await screen.findByRole('alert')).toHaveTextContent("Couldn't load threads");
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
    await screen.findByRole('button', { name: /Title t1/ });
    expect(screen.queryByRole('alert')).toBeNull();
  });
  test('failed refresh keeps cached rows on screen', async () => {
    listThreads.mockResolvedValueOnce(page([T('t1')]));
    const { unmount } = render(<GroupThreadsSection userId="u1" groupId="g1" onOpenThread={vi.fn()} />);
    await screen.findByRole('button', { name: /Title t1/ });
    unmount();
    listThreads.mockRejectedValueOnce(new Error('x'));
    render(<GroupThreadsSection userId="u1" groupId="g1" onOpenThread={vi.fn()} />);
    expect(screen.getByRole('button', { name: /Title t1/ })).toBeInTheDocument();
    expect(await screen.findByRole('alert')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Title t1/ })).toBeInTheDocument();
  });
  test('row label singular/plural', () => {
    expect(threadRowLabel({ title: 'A', reply_count: 1 })).toBe('A, 1 reply');
    expect(threadRowLabel({ reply_count: 0 })).toBe('Thread, 0 replies');
  });
});

describe('flag gating (fails closed)', () => {
  const keys = (features) => getVisibleGroupInfoSections({ features }).filter((s) => s.key === 'threads').length;
  test('threads section only when features.threads === true', () => {
    expect(GROUP_INFO_SECTIONS.find((s) => s.key === 'threads').order).toBe(30);
    expect(keys({ threads: true })).toBe(1);
    expect(keys({ threads: false })).toBe(0);
    expect(keys({})).toBe(0);
    expect(keys(undefined)).toBe(0);
    expect(keys({ threads: 1 })).toBe(0);
  });
});
