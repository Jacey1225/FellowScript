// Tests for SessionCreator.jsx. Forms restyle (20261023): the modal is a 3-step
// stepper (Basics / Study / Options) with a sticky action bar (Cancel or Back,
// Next, then Schedule / Save Changes) instead of circular icon buttons. Title
// text, "Summarize" label, and validation behavior are unchanged.
//
// Run with: cd frontend && npm test -- --run src/components/SessionCreator.test.jsx
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import SessionCreator from './SessionCreator.jsx';

// VerseSelector is unrelated to this task's changes and uses document.body
// portals / positioning logic that isn't relevant here -- stub it out so
// these tests focus on the modal chrome (title/buttons/labels) itself.
vi.mock('./VerseSelector.jsx', () => ({
  default: () => <div data-testid="verse-selector-stub" />,
}));

const BOOKS = ['Genesis', 'Exodus'];
const chapterCount = () => 3;
const verseCount = () => 10;

function renderCreator(props = {}) {
  const onClose = vi.fn();
  const onCreate = vi.fn().mockResolvedValue(true);
  const onUpdate = vi.fn().mockResolvedValue(true);
  const utils = render(
    <SessionCreator
      open={true}
      onClose={onClose}
      onCreate={onCreate}
      onUpdate={onUpdate}
      editSession={null}
      books={BOOKS}
      chapterCount={chapterCount}
      verseCount={verseCount}
      {...props}
    />
  );
  return { onClose, onCreate, onUpdate, ...utils };
}

function fillRequiredFields() {
  fireEvent.change(screen.getByPlaceholderText('Evening Study'), { target: { value: 'My Session' } });
}

const EDIT = { id: 's1', title: 'Existing', time_start: '2026-09-01T10:00:00Z', time_end: '2026-09-01T10:30:00Z' };
const primary = () => document.querySelector('.ff-btn--primary');

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe('SessionCreator — modal title', () => {
  test('reads "Schedule" when creating and "Edit Session" when editing', () => {
    renderCreator({ editSession: null });
    expect(screen.getByText('Schedule', { selector: '.ant-modal-title *, .ant-modal-title' })).toBeInTheDocument();
    cleanup();
    renderCreator({ editSession: EDIT });
    expect(screen.getByText('Edit Session')).toBeInTheDocument();
  });

  test('the title is horizontally centered in the modal header bar', () => {
    renderCreator();
    const header = document.querySelector('.ant-modal-header');
    expect(header).toBeTruthy();
    expect(header.style.textAlign).toBe('center');
  });
});

describe('SessionCreator — stepper and actions', () => {
  test('shows a 3-step rail starting at Basics, with Cancel calling onClose without submitting', () => {
    const { onClose, onCreate } = renderCreator();
    expect(screen.getByRole('list', { name: 'Progress' })).toBeInTheDocument();
    expect(screen.getByLabelText(/Step 1 of 3, Basics, current/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(onCreate).not.toHaveBeenCalled();
  });

  test('Next stays dimmed (aria-disabled) until title and start time are set', () => {
    renderCreator();
    expect(primary()).toHaveTextContent('Next');
    expect(primary()).toHaveAttribute('aria-disabled', 'true');
    fillRequiredFields();
    // Still dimmed: no start time yet (DatePicker not exercised here).
    expect(primary()).toHaveAttribute('aria-disabled', 'true');
  });

  test('editing: the primary is "Save Changes" on every step and calls onUpdate', () => {
    const { onUpdate } = renderCreator({ editSession: EDIT });
    expect(primary()).toHaveTextContent('Save Changes');
    expect(primary()).not.toHaveAttribute('aria-disabled', 'true');
    fireEvent.click(primary());
    expect(onUpdate).toHaveBeenCalledTimes(1);
    expect(onUpdate.mock.calls[0][0]).toBe('s1');
    expect(onUpdate.mock.calls[0][1]).toMatchObject({ title: 'Existing' });
  });

  test('editing: the rail jumps straight to Options, where the primary stays "Save Changes"', () => {
    renderCreator({ editSession: EDIT });
    fireEvent.click(screen.getByLabelText(/Step 3 of 3, Options/));
    expect(screen.getByLabelText(/Step 3 of 3, Options, current/)).toBeInTheDocument();
    expect(primary()).toHaveTextContent('Save Changes');
  });

  test('shows the saving state on the primary while a submit is in flight', () => {
    let resolveUpdate;
    const onUpdate = vi.fn(() => new Promise(res => { resolveUpdate = res; }));
    renderCreator({ editSession: EDIT, onUpdate });
    fireEvent.click(primary());
    expect(screen.getByRole('status', { name: 'Saving' })).toBeInTheDocument();
    resolveUpdate(true);
  });
});

describe('SessionCreator — Summarize label', () => {
  test('the summarize switch label reads "Summarize" (not "Summarize with agent"), and toggling it flips the underlying state', () => {
    renderCreator({ editSession: EDIT });
    fireEvent.click(screen.getByLabelText(/Step 3 of 3, Options/));
    expect(screen.getByText('Summarize')).toBeInTheDocument();
    expect(screen.queryByText('Summarize with agent')).not.toBeInTheDocument();

    const switches = screen.getAllByRole('switch');
    // Second switch is "Summarize" (first is "Repeat weekly"), per render order.
    const summarizeSwitch = switches[1];
    expect(summarizeSwitch).toHaveAttribute('aria-checked', 'false');
    fireEvent.click(summarizeSwitch);
    expect(summarizeSwitch).toHaveAttribute('aria-checked', 'true');
  });
});
