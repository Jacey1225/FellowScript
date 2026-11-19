// Task 20261118-public-membership-page testing: legacy #/account?subscribe=1
// link reaches /membership (not /signin -> /reader -> /download), with a safe
// rebuilt path; plain /account and the desktop shell are untouched.
import React from 'react';
import { describe, test, expect, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom';
import AccountSubscribeAlias from './AccountSubscribeAlias.jsx';

function Where() { const l = useLocation(); return <div data-testid="m">{l.pathname + l.search}</div>; }
function renderAt(url) {
  return render(
    <MemoryRouter initialEntries={[url]}>
      <Routes>
        <Route path="/membership" element={<Where />} />
        <Route path="/account" element={<AccountSubscribeAlias><div data-testid="account" /></AccountSubscribeAlias>} />
      </Routes>
    </MemoryRouter>,
  );
}
afterEach(() => { cleanup(); delete window.__TAURI_INTERNALS__; });

describe('AccountSubscribeAlias', () => {
  test('subscribe=1&seats=3 -> /membership?seats=3', () => {
    renderAt('/account?subscribe=1&seats=3');
    expect(screen.getByTestId('m').textContent).toBe('/membership?seats=3');
  });
  test('seats clamped / junk sanitized', () => {
    renderAt('/account?subscribe=1&seats=9999');
    expect(screen.getByTestId('m').textContent).toBe('/membership?seats=100');
    cleanup();
    renderAt('/account?subscribe=1&seats=500000');
    expect(screen.getByTestId('m').textContent).toBe('/membership?seats=1');
    cleanup();
    renderAt('/account?subscribe=1&seats=https://evil.com');
    expect(screen.getByTestId('m').textContent).toBe('/membership?seats=1');
  });
  test('missing seats defaults to 1', () => {
    renderAt('/account?subscribe=1');
    expect(screen.getByTestId('m').textContent).toBe('/membership?seats=1');
  });
  test.each(['/account', '/account?subscribe=0', '/account?subscribe=true', '/account?seats=3'])('%s is not aliased', (u) => {
    renderAt(u);
    expect(screen.getByTestId('account')).toBeTruthy();
  });
  test('desktop shell is not aliased', () => {
    window.__TAURI_INTERNALS__ = {};
    renderAt('/account?subscribe=1&seats=3');
    expect(screen.getByTestId('account')).toBeTruthy();
  });
});
