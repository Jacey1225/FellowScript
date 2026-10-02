// Task 20261002-shared-foundation step 9: group-info section registry ordering and empty behaviour.
import React from 'react';
import { describe, test, expect, vi, beforeAll, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor } from '@testing-library/react';

vi.mock('../lib/groupInfoApi.js', () => ({
  fetchGroupInfo: vi.fn(), renameGroup: vi.fn(), setGroupMuted: vi.fn(), setGroupMaxMembers: vi.fn(),
  uploadGroupPhoto: vi.fn(), removeGroupPhoto: vi.fn(), confirmGroupPhoto: vi.fn(),
  fetchGroupGallery: vi.fn(),
  GROUP_PHOTO_LIMITS: { maxBytes: 1, accept: ['image/png'], oversizeCopy: 'x' },
}));
import * as api from '../lib/groupInfoApi.js';
import { GROUP_INFO_SECTIONS, getVisibleGroupInfoSections } from './groupInfoSections.js';
import GroupInfoPanel, { _clearGroupInfoCaches } from './GroupInfoPanel.jsx';

beforeAll(() => { if (!Element.prototype.scrollIntoView) Element.prototype.scrollIntoView = () => {}; });
const C = (id) => () => <div data-testid={`sec-${id}`}>{id}</div>;
afterEach(() => { cleanup(); GROUP_INFO_SECTIONS.length = 0; });

describe('registry', () => {
  test('ships the registered entries in order: publish(10), join_requests(20), threads(30)', () => {
    expect(GROUP_INFO_SECTIONS.map((s) => s.order)).toEqual([10, 20, 30]);
    expect(GROUP_INFO_SECTIONS.map((s) => s.key)).toEqual(['publish', 'join_requests', 'threads']);
    expect(getVisibleGroupInfoSections({ features: {}, isOwner: true }).map((s) => s.key)).toEqual([]);
    expect(getVisibleGroupInfoSections({ features: { threads: true } }).map((s) => s.key)).toEqual(['threads']);
    expect(getVisibleGroupInfoSections({ features: { threads: true, explorer_publish: true }, isOwner: true }).map((s) => s.key)).toEqual(['publish', 'threads']);
    expect(getVisibleGroupInfoSections({ features: { threads: 'true' } }).map((s) => s.key)).toEqual([]);
    expect(getVisibleGroupInfoSections({}).map((s) => s.key)).toEqual([]);
  });
  test('sorted by order: publish 10, join_requests 20, threads 30', () => {
    const s = [
      { key: 'threads', order: 30, isVisible: () => true, component: C('threads') },
      { key: 'publish', order: 10, isVisible: () => true, component: C('publish') },
      { key: 'join_requests', order: 20, isVisible: () => true, component: C('jr') },
    ];
    expect(getVisibleGroupInfoSections({}, s).map((x) => x.key)).toEqual(['publish', 'join_requests', 'threads']);
    expect(s.map((x) => x.key)[0]).toBe('threads'); // input not mutated
  });
  test('isVisible false or throwing hides; empty list is empty', () => {
    const s = [
      { key: 'a', order: 1, isVisible: () => false, component: C('a') },
      { key: 'b', order: 2, isVisible: () => { throw new Error('x'); }, component: C('b') },
      { key: 'c', order: 3, isVisible: (ctx) => ctx.features.threads, component: C('c') },
    ];
    expect(getVisibleGroupInfoSections({ features: { threads: true } }, s).map((x) => x.key)).toEqual(['c']);
    expect(getVisibleGroupInfoSections({}, [])).toEqual([]);
  });
});

describe('GroupInfoPanel integration', () => {
  beforeEach(() => {
    _clearGroupInfoCaches();
    Object.values(api).forEach((f) => f.mockReset?.());
    api.fetchGroupInfo.mockResolvedValue({ title: 'G', photo_url: null, muted: false });
    api.fetchGroupGallery.mockResolvedValue({ items: [], has_more: false });
  });
  const panel = () => render(<GroupInfoPanel open onClose={vi.fn()} contact={{ id: 'g1', name: 'G', type: 'group' }}
    user={{ user_id: 'u1', username: 'me' }} groupMembers={[]} onGroupChanged={vi.fn()} onGroupGone={vi.fn()} />);

  test('empty registry renders no extra sections', async () => {
    const { container } = panel();
    await waitFor(() => expect(api.fetchGroupInfo).toHaveBeenCalled());
    expect(container.ownerDocument.querySelector('[data-testid^="sec-"]')).toBeNull();
  });
  test('registered sections render in order 20 then 30', async () => {
    GROUP_INFO_SECTIONS.push(
      { key: 'threads', order: 30, isVisible: () => true, component: C('threads') },
      { key: 'jrq', order: 20, isVisible: () => true, component: C('jrq') },
    );
    panel();
    const a = await screen.findByTestId('sec-jrq');
    const b = await screen.findByTestId('sec-threads');
    expect(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });
});
