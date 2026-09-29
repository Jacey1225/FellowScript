// Run with: cd frontend && npm test -- --run src/components/ReaderWebRedirect.test.jsx
import React from 'react';
import { describe, test, expect, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import ReaderWebRedirect from './ReaderWebRedirect.jsx';

afterEach(() => {
  cleanup();
  delete window.__TAURI_INTERNALS__;
});

function renderAt() {
  return render(
    <MemoryRouter initialEntries={['/reader']}>
      <Routes>
        <Route path="/reader" element={<ReaderWebRedirect><div>Reader Content</div></ReaderWebRedirect>} />
        <Route path="/download" element={<div>Download Page</div>} />
      </Routes>
    </MemoryRouter>
  );
}

describe('ReaderWebRedirect', () => {
  test('web browser is redirected to /download', () => {
    renderAt();
    expect(screen.getByText('Download Page')).toBeTruthy();
    expect(screen.queryByText('Reader Content')).toBeNull();
  });

  test('desktop app shell still gets the reader', () => {
    window.__TAURI_INTERNALS__ = {};
    renderAt();
    expect(screen.getByText('Reader Content')).toBeTruthy();
    expect(screen.queryByText('Download Page')).toBeNull();
  });
});
