// Unit tests for the shared per-route <head> manager (task
// 20260909-website-seo). This is the single source of truth every page's
// <Seo> call goes through, so a regression here would silently break
// title/canonical/OG/Twitter/JSON-LD/robots behavior across every route at
// once -- covers what no single page-level test would catch on its own.
//
// react-helmet-async commits to the real document head via
// requestAnimationFrame by default, not synchronously within render() --
// every assertion below goes through waitFor() so it doesn't race that.
//
// Run with: cd frontend && npm test -- --run src/components/Seo.test.jsx
import React from 'react';
import { describe, test, expect, afterEach } from 'vitest';
import { render, cleanup, waitFor } from '@testing-library/react';
import Seo from './Seo.jsx';

afterEach(() => cleanup());

function head(selector) {
  return document.head.querySelector(selector);
}

async function waitForHead(selector) {
  await waitFor(() => expect(head(selector)).not.toBeNull());
  return head(selector);
}

describe('Seo — per-route head tags', () => {
  test('renders title, description, a canonical built from SITE_URL + path, and index/follow by default', async () => {
    render(<Seo title="Test Page" description="A test description." path="/some-path" />);

    const description = await waitForHead('meta[name="description"]');
    expect(document.title).toBe('Test Page');
    expect(description.getAttribute('content')).toBe('A test description.');
    // No VITE_SITE_URL is set in the test environment, so config.js's
    // dev-only fallback applies here -- see config.seo-site-url.test.js for
    // the case where a real production value is set.
    expect(head('link[rel="canonical"]').getAttribute('href')).toBe('http://localhost:5173/some-path');
    expect(head('meta[name="robots"]').getAttribute('content')).toBe('index, follow');
  });

  test('noindex renders "noindex, nofollow" instead of the indexable default (the authenticated/app-route case)', async () => {
    render(<Seo title="Private Page" path="/private" noindex />);

    const robots = await waitForHead('meta[name="robots"]');
    expect(robots.getAttribute('content')).toBe('noindex, nofollow');
  });

  test('Open Graph tags mirror title/description/canonical and carry the site name', async () => {
    render(<Seo title="OG Title" description="OG desc" path="/og" />);

    await waitForHead('meta[property="og:title"]');
    expect(head('meta[property="og:type"]').getAttribute('content')).toBe('website');
    expect(head('meta[property="og:title"]').getAttribute('content')).toBe('OG Title');
    expect(head('meta[property="og:description"]').getAttribute('content')).toBe('OG desc');
    expect(head('meta[property="og:url"]').getAttribute('content')).toBe('http://localhost:5173/og');
    expect(head('meta[property="og:site_name"]').getAttribute('content')).toBe('FellowScript');
    expect(head('meta[property="og:image"]')).toBeNull();
  });

  test('Twitter card is "summary" with no image, and "summary_large_image" once an image is given -- both carry the resolved SITE_URL image', async () => {
    render(<Seo title="No image" path="/no-image" />);
    await waitForHead('meta[name="twitter:card"]');
    expect(head('meta[name="twitter:card"]').getAttribute('content')).toBe('summary');
    expect(head('meta[name="twitter:image"]')).toBeNull();

    cleanup();
    render(<Seo title="With image" path="/with-image" image="/data/logo.png" />);
    await waitFor(() => expect(head('meta[name="twitter:card"]').getAttribute('content')).toBe('summary_large_image'));
    expect(head('meta[name="twitter:image"]').getAttribute('content')).toBe('http://localhost:5173/data/logo.png');
    expect(head('meta[property="og:image"]').getAttribute('content')).toBe('http://localhost:5173/data/logo.png');
  });

  test('jsonLd accepts a single object or an array and always serializes into application/ld+json script tag(s)', async () => {
    render(<Seo title="One block" path="/one" jsonLd={{ '@type': 'Organization', name: 'FellowScript' }} />);
    await waitFor(() => expect(document.head.querySelectorAll('script[type="application/ld+json"]').length).toBe(1));
    let scripts = document.head.querySelectorAll('script[type="application/ld+json"]');
    expect(JSON.parse(scripts[0].textContent)).toEqual({ '@type': 'Organization', name: 'FellowScript' });

    cleanup();
    render(<Seo title="Two blocks" path="/two" jsonLd={[{ '@type': 'A' }, { '@type': 'B' }]} />);
    await waitFor(() => expect(document.head.querySelectorAll('script[type="application/ld+json"]').length).toBe(2));

    cleanup();
    render(<Seo title="No blocks" path="/none" />);
    await waitFor(() => expect(head('meta[name="robots"]')).not.toBeNull());
    scripts = document.head.querySelectorAll('script[type="application/ld+json"]');
    expect(scripts.length).toBe(0);
  });

  test('description-dependent tags are omitted entirely (not rendered empty) when no description is given', async () => {
    render(<Seo title="No description" path="/bare" />);

    await waitForHead('meta[name="robots"]');
    expect(head('meta[name="description"]')).toBeNull();
    expect(head('meta[property="og:description"]')).toBeNull();
    expect(head('meta[name="twitter:description"]')).toBeNull();
  });
});
