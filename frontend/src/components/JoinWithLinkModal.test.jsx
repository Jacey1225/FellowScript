// Task 20260929-group-invite-links testing: desktop paste-link flow.
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, fireEvent } from '@testing-library/react';
import JoinWithLinkModal from './JoinWithLinkModal.jsx';

const T = 'A'.repeat(43);
afterEach(() => { cleanup(); window.location.hash = ''; });

function open() {
  const onClose = vi.fn();
  render(<JoinWithLinkModal open onClose={onClose} />);
  return { onClose, input: screen.getByLabelText('Paste an invite link') };
}

describe('JoinWithLinkModal', () => {
  test('valid link navigates to the fixed #/join/<token> route', () => {
    const { input, onClose } = open();
    fireEvent.change(input, { target: { value: `https://fellowscript.com/join/${T}` } });
    fireEvent.click(screen.getByText('Continue'));
    expect(window.location.hash).toBe(`#/join/${T}`);
    expect(onClose).toHaveBeenCalled();
  });

  test('bare token works', () => {
    const { input } = open();
    fireEvent.change(input, { target: { value: T } });
    fireEvent.keyDown(input, { key: 'Enter' });
    expect(window.location.hash).toBe(`#/join/${T}`);
  });

  test.each([
    `https://evil.com/join/${T}`,
    `https://fellowscript.com/join/${T}/extra`,
    'javascript:alert(1)',
    'nonsense',
  ])('rejects %s with a visible error and no navigation', (value) => {
    const { input } = open();
    fireEvent.change(input, { target: { value } });
    fireEvent.click(screen.getByText('Continue'));
    expect(screen.getByRole('alert')).toHaveTextContent("That doesn't look like a FellowScript invite link.");
    expect(window.location.hash).toBe('');
  });
});
