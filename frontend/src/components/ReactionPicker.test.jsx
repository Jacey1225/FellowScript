// Task 20261011-desktop-chat-replies-reactions: picker keyboard + a11y.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import ReactionPicker from './ReactionPicker.jsx';

const anchor = { top: 200, bottom: 230, left: 50, right: 90 };
const mount = (over = {}) => {
  const props = { anchor, align: 'left', quick: ['👍', '❤️'], more: ['🔥', '🎉'], selected: new Set(['👍']), onPick: vi.fn(), onClose: vi.fn(), ...over };
  render(<ReactionPicker {...props} />);
  return props;
};
beforeEach(() => { window.matchMedia = vi.fn(() => ({ matches: false, addEventListener() {}, removeEventListener() {} })); });
afterEach(() => { cleanup(); vi.restoreAllMocks(); });

describe('ReactionPicker', () => {
  test('renders only the server quick row; More hidden when allowlist more is empty', () => {
    mount({ more: [] });
    expect(screen.getByRole('dialog', { name: 'Add reaction' })).toBeInTheDocument();
    expect(screen.getAllByRole('button')).toHaveLength(2);
    expect(screen.queryByRole('button', { name: 'More reactions' })).toBeNull();
  });
  test('aria-pressed reflects the viewer selection; first button focused', () => {
    mount();
    const up = screen.getByRole('button', { name: 'Thumbs up' });
    expect(up).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByRole('button', { name: 'Heart' })).toHaveAttribute('aria-pressed', 'false');
    expect(document.activeElement).toBe(up);
  });
  test('click picks the emoji', () => {
    const p = mount();
    fireEvent.click(screen.getByRole('button', { name: 'Heart' }));
    expect(p.onPick).toHaveBeenCalledWith('❤️');
  });
  test('More toggles the rest of the allowlist; expanded state exposed', () => {
    mount();
    const more = screen.getByRole('button', { name: 'More reactions' });
    expect(more).toHaveAttribute('aria-expanded', 'false');
    expect(screen.queryByRole('button', { name: 'Fire' })).toBeNull();
    fireEvent.click(more);
    expect(more).toHaveAttribute('aria-expanded', 'true');
    expect(screen.getByRole('button', { name: 'Fire' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Celebration' })).toBeInTheDocument();
  });
  test('arrow keys wrap, Home/End jump', () => {
    mount();
    const dlg = screen.getByRole('dialog');
    const btns = screen.getAllByRole('button');
    fireEvent.keyDown(dlg, { key: 'ArrowRight' });
    expect(document.activeElement).toBe(btns[1]);
    fireEvent.keyDown(dlg, { key: 'End' });
    expect(document.activeElement).toBe(btns[btns.length - 1]);
    fireEvent.keyDown(dlg, { key: 'ArrowRight' });
    expect(document.activeElement).toBe(btns[0]);
    fireEvent.keyDown(dlg, { key: 'ArrowLeft' });
    expect(document.activeElement).toBe(btns[btns.length - 1]);
  });
  test('Escape closes asking for focus return; Tab closes', () => {
    const p = mount();
    const dlg = screen.getByRole('dialog');
    fireEvent.keyDown(dlg, { key: 'Escape' });
    expect(p.onClose).toHaveBeenLastCalledWith(true);
    fireEvent.keyDown(dlg, { key: 'Tab' });
    expect(p.onClose).toHaveBeenCalledTimes(2);
  });
  test('outside pointerdown closes without focus return', () => {
    const p = mount();
    fireEvent.pointerDown(document.body);
    expect(p.onClose).toHaveBeenCalledWith(false);
  });
  test('reduced motion adds the reduced class', () => {
    window.matchMedia = vi.fn(() => ({ matches: true, addEventListener() {}, removeEventListener() {} }));
    mount();
    expect(screen.getByRole('dialog').className).toContain('msg-reaction-picker-reduced');
  });
});
