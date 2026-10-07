// Task 20261007-affiliates-page: creator Affiliates page.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor, fireEvent } from '@testing-library/react';
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom';

const mockAuth = { user: { user_id: 'u1' } };
vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => mockAuth }));
vi.mock('../components/AppNav.jsx', () => ({ default: () => null }));
vi.mock('../components/AppBloom.jsx', () => ({ default: () => null }));
vi.mock('../components/Seo.jsx', () => ({ default: () => null }));
vi.mock('../hooks/useWarmCanvas.js', () => ({ useWarmCanvas: () => {} }));
vi.mock('../lib/affiliatesApi.js', async () => {
  const actual = await vi.importActual('../lib/affiliatesApi.js');
  return { ...actual, getAffiliateOverview: vi.fn(), getAffiliateResources: vi.fn(), fetchAffiliateFile: vi.fn() };
});
import { getAffiliateOverview, getAffiliateResources, AffiliatesApiError } from '../lib/affiliatesApi.js';
import Affiliates from './Affiliates.jsx';

function Where() { const l = useLocation(); return <div data-testid="where">{l.pathname}</div>; }
function renderPage() {
  return render(
    <MemoryRouter initialEntries={['/affiliates']}>
      <Routes>
        <Route path="/affiliates" element={<Affiliates />} />
        <Route path="*" element={<Where />} />
      </Routes>
    </MemoryRouter>,
  );
}
const DATA = {
  v: 1,
  codes: [{ code: 'CEE1', active: true, link: 'https://fellowscript.com/?code=CEE1' }],
  metrics: { active_paying_subscribers: 52, monthly_earnings_cents: 12345, commission_rate: 0.35 },
  series: {
    day: [{ t: '2026-03-01', new: 1, total: 1 }, { t: '2026-03-02', new: 3, total: 4 }, { t: '2026-03-03', new: 0, total: 4 }],
    week: [{ t: '2026-02-23', new: 4, total: 4 }, { t: '2026-03-02', new: 3, total: 7 }],
    month: [{ t: '2026-02-01', new: 4, total: 4 }, { t: '2026-03-01', new: 3, total: 7 }],
  },
  milestones: [
    { subscribers: 50, bonus_cents: 10000, earned: true, earned_at: '2026-03-02' },
    { subscribers: 100, bonus_cents: 25000, earned: false, earned_at: null },
    { subscribers: 500, bonus_cents: 150000, earned: false, earned_at: null },
  ],
};
beforeEach(() => {
  mockAuth.user = { user_id: 'u1' };
  getAffiliateOverview.mockReset(); getAffiliateResources.mockReset();
});
afterEach(() => cleanup());

describe('Affiliates', () => {
  test('signed out shows prompt and makes no data request', () => {
    mockAuth.user = null;
    renderPage();
    expect(screen.getByText(/Create a FellowScript account/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Create account' })).toBeInTheDocument();
    expect(getAffiliateOverview).not.toHaveBeenCalled();
  });

  test('404 shows neutral unavailable notice', async () => {
    getAffiliateOverview.mockRejectedValue(new AffiliatesApiError('x', 404));
    renderPage();
    expect(await screen.findByText(/isn't available right now/)).toBeInTheDocument();
  });

  test('403 shows non-creator state with no data', async () => {
    getAffiliateOverview.mockRejectedValue(new AffiliatesApiError('x', 403));
    renderPage();
    expect(await screen.findByText("This account isn't set up as a creator.")).toBeInTheDocument();
    expect(screen.queryByTestId('metric-subscribers')).toBeNull();
  });

  test('401 is treated as signed out', async () => {
    getAffiliateOverview.mockRejectedValue(new AffiliatesApiError('x', 401));
    renderPage();
    expect(await screen.findByRole('button', { name: 'Sign in' })).toBeInTheDocument();
  });

  test('metrics use the response rate; charts draw no markers; toggle and hover readout work', async () => {
    getAffiliateOverview.mockResolvedValue(DATA);
    const { container } = renderPage();
    expect(await screen.findByTestId('metric-subscribers')).toHaveTextContent('52');
    expect(screen.getByTestId('metric-earnings')).toHaveTextContent('$123.45');
    expect(screen.getAllByText(/35% of/).length).toBeGreaterThan(0);
    expect(container.querySelectorAll('circle').length).toBe(0);
    expect(screen.getByTestId('chart-new').querySelectorAll('path').length).toBe(1);
    expect(screen.getByTestId('chart-total').querySelectorAll('path').length).toBe(1);

    const area = screen.getByTestId('chart-area-new');
    fireEvent.keyDown(area, { key: 'ArrowLeft' });
    expect(screen.getByTestId('readout-new')).toHaveTextContent('Mar 2: 3 new');
    fireEvent.keyDown(area, { key: 'Escape' });
    expect(screen.getByTestId('readout-new')).toHaveTextContent('');

    fireEvent.click(screen.getByText('Week'));
    fireEvent.keyDown(screen.getByTestId('chart-area-total'), { key: 'ArrowRight' });
    expect(screen.getByTestId('readout-total')).toHaveTextContent('Week of Mar 2: 7 total');
  });

  test('milestones show earned and not yet earned', async () => {
    getAffiliateOverview.mockResolvedValue(DATA);
    renderPage();
    const m50 = await screen.findByTestId('milestone-50');
    expect(m50).toHaveTextContent('Earned');
    expect(screen.getByTestId('milestone-100')).toHaveTextContent('Not yet earned');
    expect(screen.getByTestId('milestone-100')).toHaveTextContent('48 to go');
  });

  test('links panel lists the creator link without calling the resources API for scripts', async () => {
    getAffiliateOverview.mockResolvedValue(DATA);
    getAffiliateResources.mockResolvedValue({ v: 1, resources: [] });
    renderPage();
    await screen.findByTestId('metric-subscribers');
    fireEvent.click(screen.getByRole('button', { name: /Talk script and story/ }));
    expect(screen.getByText('The story of FellowScript')).toBeInTheDocument();
    expect(getAffiliateResources).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole('button', { name: /Links and QR codes/ }));
    await waitFor(() => expect(getAffiliateResources).toHaveBeenCalledTimes(1));
    expect(screen.getByLabelText('Link for code CEE1')).toHaveValue('https://fellowscript.com/?code=CEE1');
  });
});
