// Task 20260929-announcement-title-color-crop-layer-fix testing.
// Run: cd frontend && npx vitest run src/components/TitleColorPicker.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import TitleColorPicker from './TitleColorPicker.jsx';
import { TITLE_COLOR_SWATCHES } from '../lib/announcementTitleColor.js';

afterEach(cleanup);

describe('TitleColorPicker', () => {
  test('radiogroup with one named radio per swatch; default selected when value null', () => {
    render(<TitleColorPicker value={null} onChange={vi.fn()} />);
    const group = screen.getByRole('radiogroup', { name: 'Title color' });
    expect(group).toBeTruthy();
    const radios = screen.getAllByRole('radio');
    expect(radios).toHaveLength(TITLE_COLOR_SWATCHES.length);
    for (const s of TITLE_COLOR_SWATCHES) expect(screen.getByRole('radio', { name: s.name })).toBeTruthy();
    expect(screen.getByRole('radio', { name: 'Parchment (default)' })).toHaveAttribute('aria-checked', 'true');
    expect(radios.filter(r => r.getAttribute('aria-checked') === 'true')).toHaveLength(1);
    expect(screen.getByText('Title color: Parchment (default)')).toBeTruthy();
  });

  test('selected state is not color-only (check icon) and value drives selection', () => {
    const { container } = render(<TitleColorPicker value="#ffc61a" onChange={vi.fn()} />);
    const gold = screen.getByRole('radio', { name: 'Gold' });
    expect(gold).toHaveAttribute('aria-checked', 'true');
    expect(gold.querySelector('.anticon-check')).toBeTruthy();
    expect(container.querySelectorAll('.anticon-check')).toHaveLength(1);
    expect(screen.getByText('Title color: Gold')).toBeTruthy();
  });

  test('clicking a swatch reports uppercase hex; picking the default reports null', () => {
    const onChange = vi.fn();
    render(<TitleColorPicker value="#FFC61A" onChange={onChange} />);
    fireEvent.click(screen.getByRole('radio', { name: 'Sky' }));
    expect(onChange).toHaveBeenLastCalledWith('#9CD3FF');
    fireEvent.click(screen.getByRole('radio', { name: 'Parchment (default)' }));
    expect(onChange).toHaveBeenLastCalledWith(null);
  });

  test('arrow keys move selection with wraparound', () => {
    const onChange = vi.fn();
    render(<TitleColorPicker value="#FFFFFF" onChange={onChange} />);
    fireEvent.keyDown(screen.getByRole('radio', { name: 'White' }), { key: 'ArrowRight' });
    expect(onChange).toHaveBeenLastCalledWith('#FFC61A');
    fireEvent.keyDown(screen.getByRole('radio', { name: 'White' }), { key: 'ArrowLeft' });
    expect(onChange).toHaveBeenLastCalledWith(null);
  });

  test('custom picker: valid color reported uppercase; custom value shows custom name and no swatch selected', () => {
    const onChange = vi.fn();
    const { rerender } = render(<TitleColorPicker value={null} onChange={onChange} />);
    fireEvent.change(screen.getByLabelText('Custom color'), { target: { value: '#123abc' } });
    expect(onChange).toHaveBeenLastCalledWith('#123ABC');
    rerender(<TitleColorPicker value="#123ABC" onChange={onChange} />);
    expect(screen.getByText('Title color: Custom color #123ABC')).toBeTruthy();
    for (const r of screen.getAllByRole('radio')) expect(r).toHaveAttribute('aria-checked', 'false');
  });

  test('reset appears only for non-default and reports null', () => {
    const onChange = vi.fn();
    const { rerender } = render(<TitleColorPicker value={null} onChange={onChange} />);
    expect(screen.queryByText('Reset to default')).toBeNull();
    rerender(<TitleColorPicker value="#FFC61A" onChange={onChange} />);
    fireEvent.click(screen.getByText('Reset to default'));
    expect(onChange).toHaveBeenLastCalledWith(null);
  });

  test('legibility warning is non-blocking and shown only for low-contrast custom colors', () => {
    const { rerender } = render(<TitleColorPicker value="#FFC61A" onChange={vi.fn()} />);
    expect(screen.queryByRole('status')).toBeNull();
    rerender(<TitleColorPicker value="#222222" onChange={vi.fn()} />);
    expect(screen.getByRole('status').textContent).toMatch(/hard to read/);
    for (const r of screen.getAllByRole('radio')) expect(r).not.toBeDisabled();
  });

  test('disabled disables swatches, custom input and reset', () => {
    render(<TitleColorPicker value="#FFC61A" onChange={vi.fn()} disabled />);
    for (const r of screen.getAllByRole('radio')) expect(r).toBeDisabled();
    expect(screen.getByLabelText('Custom color')).toBeDisabled();
    expect(screen.getByText('Reset to default')).toBeDisabled();
  });

  test('invalid incoming value falls back to default selection', () => {
    render(<TitleColorPicker value="red; background:url(x)" onChange={vi.fn()} />);
    expect(screen.getByRole('radio', { name: 'Parchment (default)' })).toHaveAttribute('aria-checked', 'true');
  });
});
