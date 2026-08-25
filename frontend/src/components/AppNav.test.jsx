// Regression test for the Reader restyle pass (design-notes.md §2, §5;
// intake-spec.md's scope note on AppNav being shared by 4 routes): the
// "Jump or Ask" command-trigger and the unified-background `fs-nav--unified`
// modifier must both be scoped to the Reader route only. AppNav is rendered
// by Reader, Account, AdminDetectionDetail, and AdminDetections — regressing
// this route check would leak either the trigger or the header restyle onto
// routes the visual spec never covered.
//
// Run with: cd frontend && npm test -- --run src/components/AppNav.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import AppNav from './AppNav.jsx';
import { AuthProvider } from '../context/AuthContext.jsx';

// This project's vitest config runs with `globals: false`, so RTL does not
// auto-register cleanup between tests — every other *.test.jsx in this repo
// does this explicitly (see AdminGate.test.jsx, AppBloom.test.jsx, etc.).
afterEach(() => cleanup());

function renderAppNavAt(path, props = {}) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <AuthProvider>
        <AppNav {...props} />
      </AuthProvider>
    </MemoryRouter>
  );
}

const dummyCommandTrigger = {
  books: ['Genesis'],
  curBook: null,
  curChapter: null,
  chapterCount: () => 1,
  verseCount: () => 1,
  onNavigate: vi.fn(),
  onNavigateVerse: vi.fn(),
  user: null,
  agents: [],
  activeAgent: null,
  agentMessages: [],
  agentThinking: false,
  onOpenAgent: vi.fn(),
  onNewAgent: vi.fn(),
  sendAgentMessage: vi.fn(),
  curVerse: null,
  allNotes: {},
};

describe('AppNav — Reader-route scoping', () => {
  test('renders the command-trigger and the unified background class on /reader when a commandTrigger prop is passed', () => {
    const { container } = renderAppNavAt('/reader', { commandTrigger: dummyCommandTrigger });

    expect(screen.getByRole('button', { name: /Jump or Ask/i })).toBeTruthy();
    expect(container.querySelector('.fs-nav--unified')).toBeTruthy();
  });

  test('does NOT render the command-trigger on /account even if a commandTrigger prop is (incorrectly) passed', () => {
    const { container } = renderAppNavAt('/account', { commandTrigger: dummyCommandTrigger });

    expect(screen.queryByRole('button', { name: /Jump or Ask/i })).toBeFalsy();
    expect(container.querySelector('.fs-nav--unified')).toBeFalsy();
  });

  test('does not render the command-trigger on /reader when no commandTrigger prop is passed', () => {
    renderAppNavAt('/reader');
    expect(screen.queryByRole('button', { name: /Jump or Ask/i })).toBeFalsy();
  });

  test('other 3 shared routes (Account, AdminDetectionDetail-style, AdminDetections-style) never get the unified header background', () => {
    for (const path of ['/account', '/admin/detections', '/admin/detections/123']) {
      const { container, unmount } = renderAppNavAt(path, { commandTrigger: dummyCommandTrigger });
      expect(container.querySelector('.fs-nav--unified'), `expected no unified header on ${path}`).toBeFalsy();
      unmount();
    }
  });
});
