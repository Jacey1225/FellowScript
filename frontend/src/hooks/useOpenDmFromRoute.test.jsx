// Task 20261030-user-profiles testing step 8: Message button -> /reader
// location.state.openDm is consumed once, after contacts have loaded.
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { MemoryRouter, Routes, Route, useLocation } from 'react-router-dom';
import { useOpenDmFromRoute } from './useOpenDmFromRoute.js';

function Harness({ loaded, onLoad, friends, onOpen }) {
  useOpenDmFromRoute({ loaded, onLoad, friends, onOpen });
  const loc = useLocation();
  return <div data-testid="state">{JSON.stringify(loc.state)}</div>;
}

const mount = (props, state) => render(
  <MemoryRouter initialEntries={[{ pathname: '/reader', state }]}>
    <Routes><Route path="/reader" element={<Harness {...props} />} /></Routes>
  </MemoryRouter>,
);

afterEach(cleanup);

describe('useOpenDmFromRoute', () => {
  test('no openDm state: does nothing', () => {
    const onOpen = vi.fn(); const onLoad = vi.fn();
    mount({ loaded: true, onLoad, friends: [], onOpen }, null);
    expect(onOpen).not.toHaveBeenCalled();
    expect(onLoad).not.toHaveBeenCalled();
  });

  test('contacts not loaded: asks to load and does not open yet', () => {
    const onOpen = vi.fn(); const onLoad = vi.fn();
    mount({ loaded: false, onLoad, friends: [], onOpen }, { openDm: { id: 'f1', name: 'Ann' } });
    expect(onLoad).toHaveBeenCalledTimes(1);
    expect(onOpen).not.toHaveBeenCalled();
  });

  test('known friend: opens the existing contact once and clears route state', () => {
    const onOpen = vi.fn();
    const friend = { id: 'f1', name: 'Ann', type: 'friend' };
    mount({ loaded: true, onLoad: vi.fn(), friends: [friend], onOpen }, { openDm: { id: 'f1', name: 'Ann' } });
    expect(onOpen).toHaveBeenCalledTimes(1);
    expect(onOpen).toHaveBeenCalledWith(friend);
    expect(screen.getByTestId('state').textContent).toBe('null');
  });

  test('unknown friend: opens a synthesized friend contact built from the route state', () => {
    const onOpen = vi.fn();
    mount({ loaded: true, onLoad: vi.fn(), friends: [], onOpen }, { openDm: { id: 'f2', name: 'Bo', photoUrl: 'p.png' } });
    expect(onOpen).toHaveBeenCalledWith({ id: 'f2', name: 'Bo', type: 'friend', toUsers: ['f2'], preview: '', photoUrl: 'p.png' });
  });
});
