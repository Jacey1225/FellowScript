// Home page Group plan price must follow the seat formula (api/config/seat_pricing.json
// mirrored in lib/seatPricing.js): one seat is $5.00, not the retired $4.99.
// Run: cd frontend && npm test -- --run src/pages/Home.pricing.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import Home from './Home.jsx';

vi.mock('../context/AuthContext.jsx', () => ({ useAuth: () => ({ user: null }) }));

afterEach(() => { cleanup(); vi.restoreAllMocks(); });

describe('Home Group plan price', () => {
  test('shows From $5.00 and no retired $4.99', () => {
    const { container } = render(<MemoryRouter initialEntries={['/']}><Home /></MemoryRouter>);
    expect(screen.getByText('From $5.00')).toBeTruthy();
    expect(container.textContent).not.toContain('4.99');
  });
});
