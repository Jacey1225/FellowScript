// Task 20261008-explore-page-indexable. Client <Seo> on Explore: noindex until
// the runtime browse-flag probe reports on; index, follow only when on, and a
// failed/off probe stays noindex (runtime flag-off wins over a stale prerender).
//
// Run with: cd frontend && npm test -- --run src/pages/Explore.seo.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach, beforeEach } from 'vitest';
import { render, cleanup, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';

vi.mock('../components/AppNav.jsx', () => ({ default: () => <div /> }));
vi.mock('../components/AppBloom.jsx', () => ({ default: () => null }));
vi.mock('../hooks/useWarmCanvas.js', () => ({ useWarmCanvas: () => {} }));

const probe = vi.fn();
vi.mock('../lib/explorerApi.js', async (orig) => {
  const real = await orig();
  return {
    ...real,
    probeExploreConfig: (...a) => probe(...a),
    fetchFilters: () => Promise.resolve(null),
    fetchListings: () => Promise.resolve({ items: [], page: { has_more: false } }),
  };
});

import Explore from './Explore.jsx';
import { resetExploreProbeForTests } from '../hooks/useExploreEnabled.js';

const robots = () => document.head.querySelector('meta[name="robots"]')?.getAttribute('content');

beforeEach(() => { resetExploreProbeForTests(); probe.mockReset(); });
afterEach(() => { cleanup(); });

function mount() {
  return render(<MemoryRouter><Explore /></MemoryRouter>);
}

describe('Explore route SEO', () => {
  test('flag on: index, follow, canonical /explore/, JSON-LD present', async () => {
    probe.mockResolvedValue(true);
    mount();
    await waitFor(() => expect(robots()).toBe('index, follow'));
    expect(document.head.querySelector('link[rel="canonical"]').getAttribute('href')).toMatch(/\/explore\/$/);
    expect(document.head.querySelector('script[type="application/ld+json"]')).not.toBeNull();
  });

  test('flag off: noindex', async () => {
    probe.mockResolvedValue(false);
    mount();
    await waitFor(() => expect(robots()).toMatch(/noindex/));
    await new Promise((r) => setTimeout(r, 30));
    expect(robots()).toMatch(/noindex/);
  });

  test('probe pending: noindex (fails closed)', async () => {
    probe.mockReturnValue(new Promise(() => {}));
    mount();
    await waitFor(() => expect(robots()).toMatch(/noindex/));
    await new Promise((r) => setTimeout(r, 30));
    expect(robots()).toMatch(/noindex/);
  });
});
