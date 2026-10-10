// Task 20261010-listing-detail-polish. The category chip groups on the Explore
// listing detail page live behind one "Details" disclosure button.
//
// Run with: cd frontend && npm test -- --run src/pages/ExploreListing.details.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, cleanup, screen, fireEvent, waitFor } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';

vi.mock('../components/AppNav.jsx', () => ({ default: () => <div /> }));
vi.mock('../components/AppBloom.jsx', () => ({ default: () => null }));
vi.mock('../hooks/useWarmCanvas.js', () => ({ useWarmCanvas: () => {} }));
vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => ({ user: null }) }));
vi.mock('../components/explore/JoinCtaSlot.jsx', () => ({ default: () => null }));
vi.mock('../components/explore/ReportListing.jsx', () => ({ default: () => null }));

const fetchListing = vi.fn();
vi.mock('../lib/explorerApi.js', async (orig) => {
  const real = await orig();
  return {
    ...real,
    fetchFilters: () => Promise.resolve(null),
    fetchListing: (...a) => fetchListing(...a),
  };
});

import ExploreListing from './ExploreListing.jsx';

afterEach(() => { cleanup(); fetchListing.mockReset(); });

const base = {
  public_id: 'abcdefghijkl',
  title: 'College Boys',
  summary: 'Small Group of College Boys',
  size_bucket: '5-10',
  seats: 'open',
  description_blocks: [],
};

async function mount(listing) {
  fetchListing.mockResolvedValue({ ...base, ...listing });
  const { container } = render(
    <MemoryRouter initialEntries={['/explore/abcdefghijkl']}>
      <Routes><Route path="/explore/:publicId" element={<ExploreListing />} /></Routes>
    </MemoryRouter>,
  );
  await waitFor(() => expect(container.querySelector('.ex-detail')).not.toBeNull());
  return container;
}

describe('ExploreListing Details disclosure', () => {
  test('collapsed by default: aria-expanded false, panel hidden, linked via aria-controls', async () => {
    const c = await mount({ goals: ['a'], hobbies: ['b'], free_tags: ['tagone'] });
    const btn = screen.getByRole('button', { name: /details/i });
    expect(btn.getAttribute('aria-expanded')).toBe('false');
    const panel = c.querySelector(`#${CSS.escape(btn.getAttribute('aria-controls'))}`);
    expect(panel).not.toBeNull();
    expect(panel.hidden).toBe(true);
  });

  test('click toggles open and closed; groups and Tags live inside the panel', async () => {
    const c = await mount({ goals: ['a'], hobbies: ['b'], age_ranges: ['18-24'], free_tags: ['tagone'] });
    const btn = screen.getByRole('button', { name: /details/i });
    const panel = c.querySelector(`#${CSS.escape(btn.getAttribute('aria-controls'))}`);
    fireEvent.click(btn);
    expect(btn.getAttribute('aria-expanded')).toBe('true');
    expect(panel.hidden).toBe(false);
    const titles = [...panel.querySelectorAll('.ex-chipgroup-title')].map((n) => n.textContent);
    expect(titles).toEqual(['Goals', 'Hobbies', 'Age range', 'Tags']);
    expect(panel.textContent).toContain('tagone');
    fireEvent.click(btn);
    expect(btn.getAttribute('aria-expanded')).toBe('false');
    expect(panel.hidden).toBe(true);
  });

  test('is a native button (keyboard Enter/Space come for free)', async () => {
    await mount({ goals: ['a'] });
    const btn = screen.getByRole('button', { name: /details/i });
    expect(btn.tagName).toBe('BUTTON');
    expect(btn.getAttribute('type')).toBe('button');
  });

  test('no categories: Details button and panel are not rendered', async () => {
    const c = await mount({ goals: [], free_tags: [] });
    expect(screen.queryByRole('button', { name: /details/i })).toBeNull();
    expect(c.querySelector('.ex-details')).toBeNull();
  });

  test('summary is still rendered outside the disclosure', async () => {
    const c = await mount({ goals: ['a'] });
    const s = c.querySelector('.ex-detail-summary');
    expect(s.textContent).toBe('Small Group of College Boys');
    expect(s.closest('.ex-details')).toBeNull();
  });
});
