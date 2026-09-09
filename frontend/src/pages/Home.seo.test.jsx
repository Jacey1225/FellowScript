// SEO-specific coverage for Home.jsx (task 20260909-website-seo), alongside
// the existing Home.download-section.test.jsx. Covers the acceptance
// criteria unique to the Home route: a real title/description reflecting
// FellowScript's actual purpose, Open Graph/Twitter tags backed by the real
// brand asset (not a placeholder), and the Organization+WebSite JSON-LD
// pair.
//
// react-helmet-async commits to the real document head via
// requestAnimationFrame by default, not synchronously within render() --
// every assertion below goes through waitFor() so it doesn't race that.
//
// Run with: cd frontend && npm test -- --run src/pages/Home.seo.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, cleanup, waitFor } from '@testing-library/react';
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

function head(selector) {
  return document.head.querySelector(selector);
}

describe('Home — SEO head tags (task 20260909-website-seo)', () => {
  test('title/description reflect FellowScript\'s real purpose, canonical points at "/", and the route is indexable', async () => {
    renderHome();

    await waitFor(() => expect(head('meta[name="description"]')).not.toBeNull());
    expect(document.title).toBe('FellowScript — Walk with God, Together');
    expect(head('meta[name="description"]').getAttribute('content')).toMatch(/Bible reading companion/i);
    expect(head('link[rel="canonical"]').getAttribute('href')).toBe('http://localhost:5173/');
    expect(head('meta[name="robots"]').getAttribute('content')).toBe('index, follow');
  });

  test('Open Graph/Twitter carry the real brand asset (data/logo.png), not a placeholder image', async () => {
    renderHome();

    await waitFor(() => expect(head('meta[property="og:image"]')).not.toBeNull());
    expect(head('meta[property="og:image"]').getAttribute('content')).toBe('http://localhost:5173/data/logo.png');
    expect(head('meta[name="twitter:card"]').getAttribute('content')).toBe('summary_large_image');
    expect(head('meta[property="og:site_name"]').getAttribute('content')).toBe('FellowScript');
  });

  test('ships an Organization + WebSite JSON-LD pair, each pointing at the real SITE_URL', async () => {
    renderHome();

    await waitFor(() => {
      expect(document.head.querySelectorAll('script[type="application/ld+json"]').length).toBe(2);
    });
    const scripts = Array.from(document.head.querySelectorAll('script[type="application/ld+json"]'));
    const blocks = scripts.map((s) => JSON.parse(s.textContent));

    const org = blocks.find((b) => b['@type'] === 'Organization');
    expect(org).toBeTruthy();
    expect(org.name).toBe('FellowScript');
    expect(org.url).toBe('http://localhost:5173');
    expect(org.logo).toBe('http://localhost:5173/data/logo.png');

    const site = blocks.find((b) => b['@type'] === 'WebSite');
    expect(site).toBeTruthy();
    expect(site.name).toBe('FellowScript');
    expect(site.url).toBe('http://localhost:5173');
  });
});
