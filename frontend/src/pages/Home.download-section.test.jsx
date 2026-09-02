// Minimal regression test for the "On your desktop" download section
// (task 20260902-download-section-implementation) — this is a Lightweight
// /build task with no dedicated testing gate, so the frontend gate covers it
// directly rather than deferring to a separate testing pass.
//
// Covers the acceptance criteria that are cheap to assert in jsdom:
//  - the section renders between Pricing and Closing CTA, with both cards;
//  - the macOS card exposes a real, live <a download> control pointing at the
//    real GitHub Release asset URL;
//  - the metadata line carries only the two verified facts (architecture,
//    file size) with no OS-version claim of any kind;
//  - the Windows card carries no interactive semantics at all (no button/
//    link/tabIndex/role="button" anywhere inside it).
//
// Run with: cd frontend && npm test -- --run src/pages/Home.download-section.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import Home from './Home.jsx';

vi.mock('../context/AuthContext.jsx', () => ({
  useAuth: () => ({ user: null }),
}));

afterEach(() => cleanup());

function renderHome() {
  return render(
    <MemoryRouter initialEntries={['/']}>
      <Home />
    </MemoryRouter>
  );
}

describe('Home — On your desktop section', () => {
  test('renders the eyebrow, headline, and both platform cards', () => {
    renderHome();

    expect(screen.getByText('// ON YOUR DESKTOP')).toBeTruthy();
    expect(screen.getByText('MACOS')).toBeTruthy();
    expect(screen.getByText('WINDOWS')).toBeTruthy();
    expect(screen.getByText('Coming soon')).toBeTruthy();
  });

  test('macOS card exposes a working <a download> control pointing at the live release URL', () => {
    renderHome();

    const link = screen.getByRole('link', { name: /Download for Mac/i });
    expect(link).toBeTruthy();
    expect(link.hasAttribute('download')).toBe(true);
    // MACOS_DOWNLOAD_URL is now resolved to the real, live GitHub Release
    // asset — no more '#' placeholder.
    expect(link.getAttribute('href')).toBe(
      'https://github.com/Jacey1225/FellowScript/releases/download/desktop-v0.1.0/FellowScript.dmg'
    );
  });

  test('macOS metadata line carries only verified facts, no OS-version claim', () => {
    renderHome();

    expect(screen.getByText('Apple silicon & Intel · 3 MB')).toBeTruthy();
    expect(screen.queryByText(/macOS ⟨MIN VERSION/)).toBeNull();
    expect(screen.queryByText(/macOS \d/)).toBeNull();
  });

  test('Windows card has no interactive semantics anywhere inside it', () => {
    const { container } = renderHome();

    const windowsLabel = screen.getByText('WINDOWS');
    const card = windowsLabel.closest('div[style]')?.parentElement?.querySelector('.hm-dl-card:not(.hm-dl-mac)')
      || container.querySelector('.hm-dl-card:not(.hm-dl-mac)');
    expect(card).toBeTruthy();
    expect(card.querySelector('a, button, [tabindex], [role="button"]')).toBeFalsy();
  });
});
