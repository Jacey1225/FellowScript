// Task 20261030-user-profiles testing step 8: inline bio editor.
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react';
import BioEditor from './BioEditor.jsx';

const type = (text) => fireEvent.change(screen.getByLabelText('Bio'), { target: { value: text } });
const saveBtn = () => screen.getByRole('button', { name: /save/i });

afterEach(cleanup);

describe('BioEditor', () => {
  test('starts with the initial text and a normal counter', () => {
    render(<BioEditor initial="Hello" onSave={vi.fn()} onCancel={vi.fn()} />);
    expect(screen.getByLabelText('Bio')).toHaveValue('Hello');
    expect(screen.getByText('5/160')).toBeInTheDocument();
  });

  test('warn at 20 left; over limit disables Save and shows how far over', () => {
    render(<BioEditor initial="" onSave={vi.fn()} onCancel={vi.fn()} />);
    type('a'.repeat(140));
    expect(screen.getAllByText('20 left').length).toBeGreaterThan(0);
    expect(saveBtn()).not.toBeDisabled();
    type('a'.repeat(163));
    expect(screen.getAllByText('Over by 3').length).toBeGreaterThan(0);
    expect(saveBtn()).toBeDisabled();
  });

  test('over-limit paste is kept verbatim, never cut', () => {
    render(<BioEditor initial="" onSave={vi.fn()} onCancel={vi.fn()} />);
    type('b'.repeat(200));
    expect(screen.getByLabelText('Bio').value).toHaveLength(200);
  });

  test('Save sends the draft text as typed (server normalizes)', async () => {
    const onSave = vi.fn().mockResolvedValue();
    render(<BioEditor initial="" onSave={onSave} onCancel={vi.fn()} />);
    type('  hi   there ');
    fireEvent.click(saveBtn());
    await waitFor(() => expect(onSave).toHaveBeenCalledWith('  hi   there '));
  });

  test('failed save keeps the draft, shows the server message inline, and Save is available again', async () => {
    const onSave = vi.fn().mockRejectedValue(new Error('Bios are plain text, so links can not be saved.'));
    render(<BioEditor initial="" onSave={onSave} onCancel={vi.fn()} />);
    type('my draft');
    fireEvent.click(saveBtn());
    expect(await screen.findByRole('alert')).toHaveTextContent('Bios are plain text');
    expect(screen.getByLabelText('Bio')).toHaveValue('my draft');
    await waitFor(() => expect(saveBtn()).not.toBeDisabled());
  });

  test('Cancel and Escape call onCancel', () => {
    const onCancel = vi.fn();
    render(<BioEditor initial="x" onSave={vi.fn()} onCancel={onCancel} />);
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    fireEvent.keyDown(screen.getByLabelText('Bio'), { key: 'Escape' });
    expect(onCancel).toHaveBeenCalledTimes(2);
  });

  test('Save does nothing while over the limit', () => {
    const onSave = vi.fn();
    render(<BioEditor initial="" onSave={onSave} onCancel={vi.fn()} />);
    type('c'.repeat(161));
    fireEvent.click(saveBtn());
    expect(onSave).not.toHaveBeenCalled();
  });
});
