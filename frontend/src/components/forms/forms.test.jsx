import React from 'react';
import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import { Field, shouldShowCounter, ToggleRow, ChipGroup, Segmented, StepperRail, StickyActionBar, FormErrorSummary, NumberStepper } from './index.js';

afterEach(cleanup);

describe('forms kit', () => {
  it('Field wires label, error and describedby', () => {
    render(<Field label="Title" required value="" onChange={() => {}} error="Add a title." />);
    const input = screen.getByLabelText(/Title/);
    expect(input).toHaveAttribute('aria-invalid', 'true');
    expect(input).toHaveAttribute('aria-required', 'true');
    expect(document.getElementById(input.getAttribute('aria-describedby'))).toHaveTextContent('Add a title.');
  });

  it('Field keeps caller autoComplete and masks secure input until revealed', () => {
    render(<Field label="Password" secure autoComplete="current-password" value="x" onChange={() => {}} />);
    const input = screen.getByLabelText('Password');
    expect(input).toHaveAttribute('type', 'password');
    expect(input).toHaveAttribute('autocomplete', 'current-password');
    fireEvent.click(screen.getByLabelText('Show password'));
    expect(input).toHaveAttribute('type', 'text');
    fireEvent.blur(screen.getByLabelText('Hide password'));
    expect(input).toHaveAttribute('type', 'password');
  });

  it('counter appears at 80% of the limit', () => {
    expect(shouldShowCounter(79, 100)).toBe(false);
    expect(shouldShowCounter(80, 100)).toBe(true);
    expect(shouldShowCounter(5, undefined)).toBe(false);
  });

  it('ToggleRow is a switch and toggles on Space', () => {
    const onChange = vi.fn();
    render(<ToggleRow title="Mute" checked={false} onChange={onChange} />);
    const sw = screen.getByRole('switch');
    fireEvent.keyDown(sw, { key: ' ' });
    expect(onChange).toHaveBeenCalledWith(true);
  });

  it('ChipGroup single-select acts as radiogroup, multi as pressed toggles', () => {
    const onChange = vi.fn();
    const opts = [{ value: 'a', label: 'A' }, { value: 'b', label: 'B' }];
    const { rerender } = render(<ChipGroup options={opts} value="a" onChange={onChange} />);
    expect(screen.getByRole('radio', { name: /A/ })).toHaveAttribute('aria-checked', 'true');
    fireEvent.click(screen.getByRole('radio', { name: 'B' }));
    expect(onChange).toHaveBeenCalledWith('b');
    rerender(<ChipGroup options={opts} multi value={['a']} onChange={onChange} />);
    fireEvent.click(screen.getByRole('button', { name: 'B' }));
    expect(onChange).toHaveBeenCalledWith(['a', 'b']);
  });

  it('Segmented selects', () => {
    const onChange = vi.fn();
    render(<Segmented options={[{ value: 'now', label: 'Now' }, { value: 'later', label: 'Schedule' }]} value="now" onChange={onChange} />);
    fireEvent.click(screen.getByRole('radio', { name: 'Schedule' }));
    expect(onChange).toHaveBeenCalledWith('later');
  });

  it('StepperRail marks current, blocks unreachable steps', () => {
    const onSelect = vi.fn();
    render(<StepperRail steps={['Content', 'Style', 'Publish']} current={1} maxReachable={1} onSelect={onSelect} />);
    expect(screen.getByRole('listitem', { current: 'step' })).toBeInTheDocument();
    expect(screen.getByLabelText(/Step 3 of 3/)).toBeDisabled();
    fireEvent.click(screen.getByLabelText(/Step 1 of 3/));
    expect(onSelect).toHaveBeenCalledWith(0);
  });

  it('StickyActionBar primary stays clickable when aria-disabled so validation runs', () => {
    const onPrimary = vi.fn();
    render(<StickyActionBar primaryLabel="Post" primaryDisabled onPrimary={onPrimary} secondaryLabel="Cancel" />);
    const btn = screen.getByRole('button', { name: 'Post' });
    expect(btn).toHaveAttribute('aria-disabled', 'true');
    expect(btn).not.toBeDisabled();
    fireEvent.click(btn);
    expect(onPrimary).toHaveBeenCalled();
  });

  it('FormErrorSummary lists fields and selects', () => {
    const onSelect = vi.fn();
    render(<FormErrorSummary items={[{ id: 't', name: 'Title' }, { id: 'm', name: 'Message' }]} onSelect={onSelect} />);
    expect(screen.getByRole('alert')).toHaveTextContent('2 things need attention');
    fireEvent.click(screen.getByText('Message'));
    expect(onSelect).toHaveBeenCalledWith('m');
  });

  it('NumberStepper clamps', () => {
    const onChange = vi.fn();
    render(<NumberStepper value={1} min={1} max={3} onChange={onChange} />);
    expect(screen.getByLabelText('Decrease')).toBeDisabled();
    fireEvent.click(screen.getByLabelText('Increase'));
    expect(onChange).toHaveBeenCalledWith(2);
  });
});
