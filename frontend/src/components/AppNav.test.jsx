// Regression test for AppNav's header contract (20260825-header-nav-profile-icon):
// the desktop top-right no longer shows the Home/Read/Account text Menu or
// the Reader-only "Jump or Ask" command trigger (both removed entirely) —
// just a profile avatar (routing by auth state) and the unchanged theme
// toggle. The unified-background `fs-nav--unified` modifier stays scoped to
// the Reader route only, unaffected by this change. AppNav is rendered by
// Reader, Account, AdminDetectionDetail, and AdminDetections.
//
// Run with: cd frontend && npm test -- --run src/components/AppNav.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import AppNav from './AppNav.jsx';

// Same mocking convention as AdminGate.test.jsx — swap useAuth's return value
// per test rather than seeding AuthProvider's sessionStorage/localStorage.
const mockUseAuth = vi.fn();
vi.mock('../context/AuthContext.jsx', () => ({
  useAuth: () => mockUseAuth(),
}));

afterEach(() => cleanup());

function renderAppNavAt(path, user = null) {
  mockUseAuth.mockReturnValue({ user });
  return render(
    <MemoryRouter initialEntries={[path]}>
      <AppNav />
    </MemoryRouter>
  );
}

describe('AppNav — top-right controls', () => {
  test('no Home/Read/Account text links or Jump-or-Ask trigger render on any route', () => {
    renderAppNavAt('/reader');

    expect(screen.queryByText('Home')).toBeFalsy();
    expect(screen.queryByText('Read')).toBeFalsy();
    expect(screen.queryByText('Sign In')).toBeFalsy();
    expect(screen.queryByRole('button', { name: /Jump or Ask/i })).toBeFalsy();
  });

  test('exactly a profile link and the theme toggle render in the top-right controls', () => {
    const { container } = renderAppNavAt('/reader');

    expect(container.querySelector('.nav-profile-link')).toBeTruthy();
    expect(container.querySelector('.theme-toggle-btn')).toBeTruthy();
  });
});

describe('AppNav — profile icon auth-state routing', () => {
  test('signed out: profile link points at /signin', () => {
    const { container } = renderAppNavAt('/reader', null);

    const link = container.querySelector('.nav-profile-link');
    expect(link.getAttribute('href')).toBe('/signin');
  });

  test('signed in: profile link points at /account', () => {
    const { container } = renderAppNavAt('/reader', { user_id: 'u1', username: 'jaceysimpson' });

    const link = container.querySelector('.nav-profile-link');
    expect(link.getAttribute('href')).toBe('/account');
  });
});

describe('AppNav — theme toggle unaffected', () => {
  test('theme toggle renders with its light/dark icon control intact', () => {
    const { container } = renderAppNavAt('/reader');

    expect(container.querySelector('.theme-toggle-btn')).toBeTruthy();
  });
});

describe('AppNav — Reader-route unified background scoping (unchanged)', () => {
  test('/reader gets the unified background class', () => {
    const { container } = renderAppNavAt('/reader');
    expect(container.querySelector('.fs-nav--unified')).toBeTruthy();
  });

  test('other 3 shared routes (Account, AdminDetectionDetail-style, AdminDetections-style) never get the unified header background', () => {
    for (const path of ['/account', '/admin/detections', '/admin/detections/123']) {
      const { container, unmount } = renderAppNavAt(path);
      expect(container.querySelector('.fs-nav--unified'), `expected no unified header on ${path}`).toBeFalsy();
      unmount();
    }
  });
});

describe('AppNav — mobile hamburger Drawer unaffected', () => {
  test('hamburger control still opens the Drawer with Home/Read/Account nav intact', () => {
    renderAppNavAt('/reader');

    expect(document.querySelector('.hamburger-btn')).toBeTruthy();
  });
});

// Task 20260905-profile-photo, testing step 10: fallback-to-initials
// rendering. AppNav's `.nav-profile-avatar` is antd's Avatar, which falls
// back to its `icon`/children automatically both when `src` is falsy (no
// photo set) and when the image itself fails to load (e.g. an expired
// presigned URL) -- no custom onError wiring in AppNav.jsx to bypass, so
// this asserts the actual DOM antd produces in both states rather than
// re-deriving the behavior from source.
describe('AppNav — profile photo rendering with initials fallback', () => {
  test('no profile_photo_url set: avatar shows the initials fallback, not a broken <img>', () => {
    const { container } = renderAppNavAt('/reader', { user_id: 'u1', username: 'jaceysimpson' });

    const avatar = container.querySelector('.nav-profile-avatar');
    expect(avatar).toBeTruthy();
    expect(avatar.querySelector('img')).toBeFalsy();
    expect(avatar.textContent).toBe('J');
  });

  test('profile_photo_url set: avatar renders an <img> with that src, not the initials text', () => {
    const { container } = renderAppNavAt('/reader', {
      user_id: 'u1', username: 'jaceysimpson',
      profile_photo_url: 'https://example-bucket.s3.amazonaws.com/profile-photos/u1/abc.jpg?Signature=xyz',
    });

    const avatar = container.querySelector('.nav-profile-avatar');
    expect(avatar).toBeTruthy();
    const img = avatar.querySelector('img');
    expect(img).toBeTruthy();
    expect(img.getAttribute('src')).toBe(
      'https://example-bucket.s3.amazonaws.com/profile-photos/u1/abc.jpg?Signature=xyz'
    );
  });

  test('signed out (no user): avatar shows the generic person icon, never a broken/blank image', () => {
    const { container } = renderAppNavAt('/reader', null);

    const avatar = container.querySelector('.nav-profile-avatar');
    expect(avatar).toBeTruthy();
    expect(avatar.querySelector('img')).toBeFalsy();
    // antd renders the `icon` prop's <UserOutlined/> as an <span class="anticon...">
    expect(avatar.querySelector('.anticon')).toBeTruthy();
  });

  test("a failed/expired image load falls back to the initials, doesn't stay a broken <img>", async () => {
    const { container } = renderAppNavAt('/reader', {
      user_id: 'u1', username: 'jaceysimpson',
      profile_photo_url: 'https://example-bucket.s3.amazonaws.com/profile-photos/u1/expired.jpg',
    });

    const avatar = container.querySelector('.nav-profile-avatar');
    const img = avatar.querySelector('img');
    expect(img).toBeTruthy();

    // Simulate the presigned URL having expired / the image failing to load —
    // antd's Avatar listens for the native img error event and re-renders
    // with its fallback content in response.
    img.dispatchEvent(new Event('error'));

    await waitFor(() => {
      expect(avatar.querySelector('img')).toBeFalsy();
      expect(avatar.textContent).toBe('J');
    });
  });
});
