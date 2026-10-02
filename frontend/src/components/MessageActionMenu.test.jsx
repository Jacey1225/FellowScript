// Task 20261001-message-threads step 9: anchored action menu (keyboard
// alternative to long-press, aria roles, focus management, touch hold).
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, act } from '@testing-library/react';
import ActionableBubble from './MessageActionMenu.jsx';

const mk = () => [
  { key: 'a', label: 'Start thread', onSelect: vi.fn() },
  { key: 'b', label: 'Copy', onSelect: vi.fn() },
  { key: 'c', label: 'Delete', destructive: true, onSelect: vi.fn() },
];
const bubble = (actions) => render(<ActionableBubble actions={actions} mine={false} className="msg-bubble" data-testid="bub">hello</ActionableBubble>);

beforeEach(() => { window.matchMedia = vi.fn(() => ({ matches: false, addEventListener() {}, removeEventListener() {} })); });
afterEach(() => { cleanup(); vi.useRealTimers(); vi.restoreAllMocks(); });

describe('trigger and roles', () => {
  test('no actions: plain bubble, no trigger', () => {
    bubble([]);
    expect(screen.queryByRole('button', { name: 'More actions' })).toBeNull();
    expect(screen.getByTestId('bub').className).not.toContain('actionable');
  });
  test('trigger exposes aria-haspopup and aria-expanded', () => {
    bubble(mk());
    const t = screen.getByRole('button', { name: 'More actions' });
    expect(t).toHaveAttribute('aria-haspopup', 'menu');
    expect(t).toHaveAttribute('aria-expanded', 'false');
    fireEvent.click(t);
    expect(t).toHaveAttribute('aria-expanded', 'true');
    expect(screen.getByRole('menu', { name: 'Message actions' })).toBeInTheDocument();
    expect(screen.getAllByRole('menuitem').map((e) => e.textContent)).toEqual(['Start thread', 'Copy', 'Delete']);
  });
});

describe('keyboard', () => {
  test('first item focused on open; arrows wrap; Home/End', () => {
    bubble(mk());
    fireEvent.click(screen.getByRole('button', { name: 'More actions' }));
    const items = screen.getAllByRole('menuitem');
    expect(document.activeElement).toBe(items[0]);
    const menu = screen.getByRole('menu');
    fireEvent.keyDown(menu, { key: 'ArrowDown' });
    expect(document.activeElement).toBe(items[1]);
    fireEvent.keyDown(menu, { key: 'End' });
    expect(document.activeElement).toBe(items[2]);
    fireEvent.keyDown(menu, { key: 'ArrowDown' });
    expect(document.activeElement).toBe(items[0]);
    fireEvent.keyDown(menu, { key: 'ArrowUp' });
    expect(document.activeElement).toBe(items[2]);
    fireEvent.keyDown(menu, { key: 'Home' });
    expect(document.activeElement).toBe(items[0]);
  });
  test('ArrowDown on the trigger opens the menu', () => {
    bubble(mk());
    fireEvent.keyDown(screen.getByRole('button', { name: 'More actions' }), { key: 'ArrowDown' });
    expect(screen.getByRole('menu')).toBeInTheDocument();
  });
  test('Escape closes and returns focus to the trigger', () => {
    bubble(mk());
    const t = screen.getByRole('button', { name: 'More actions' });
    fireEvent.click(t);
    fireEvent.keyDown(screen.getByRole('menu'), { key: 'Escape' });
    expect(screen.queryByRole('menu')).toBeNull();
    expect(document.activeElement).toBe(t);
  });
  test('Tab closes the menu', () => {
    bubble(mk());
    fireEvent.click(screen.getByRole('button', { name: 'More actions' }));
    fireEvent.keyDown(screen.getByRole('menu'), { key: 'Tab' });
    expect(screen.queryByRole('menu')).toBeNull();
  });
  test('picking an item closes, restores focus, and runs onSelect once', () => {
    const actions = mk();
    bubble(actions);
    const t = screen.getByRole('button', { name: 'More actions' });
    fireEvent.click(t);
    fireEvent.click(screen.getByRole('menuitem', { name: 'Copy' }));
    expect(actions[1].onSelect).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole('menu')).toBeNull();
    expect(document.activeElement).toBe(t);
  });
  test('outside pointerdown dismisses without stealing focus', () => {
    bubble(mk());
    fireEvent.click(screen.getByRole('button', { name: 'More actions' }));
    fireEvent.pointerDown(document.body);
    expect(screen.queryByRole('menu')).toBeNull();
  });
});

describe('pointer', () => {
  test('right-click opens; on a link it does not', () => {
    render(<ActionableBubble actions={mk()} className="b" data-testid="bub">hi <a href="https://x.y">link</a></ActionableBubble>);
    fireEvent.contextMenu(screen.getByText('link'));
    expect(screen.queryByRole('menu')).toBeNull();
    fireEvent.contextMenu(screen.getByTestId('bub'));
    expect(screen.getByRole('menu')).toBeInTheDocument();
  });
  test('touch hold of 500 ms opens the menu', () => {
    vi.useFakeTimers();
    bubble(mk());
    fireEvent.pointerDown(screen.getByTestId('bub'), { pointerType: 'touch', clientX: 5, clientY: 5 });
    act(() => { vi.advanceTimersByTime(499); });
    expect(screen.queryByRole('menu')).toBeNull();
    act(() => { vi.advanceTimersByTime(2); });
    expect(screen.getByRole('menu')).toBeInTheDocument();
  });
  test('moving more than 10 px or lifting cancels the hold', () => {
    vi.useFakeTimers();
    bubble(mk());
    const b = screen.getByTestId('bub');
    fireEvent.pointerDown(b, { pointerType: 'touch', clientX: 0, clientY: 0 });
    fireEvent.pointerMove(b, { pointerType: 'touch', clientX: 20, clientY: 0 });
    act(() => { vi.advanceTimersByTime(600); });
    expect(screen.queryByRole('menu')).toBeNull();
    fireEvent.pointerDown(b, { pointerType: 'touch', clientX: 0, clientY: 0 });
    fireEvent.pointerUp(b);
    act(() => { vi.advanceTimersByTime(600); });
    expect(screen.queryByRole('menu')).toBeNull();
  });
  test('mouse press does not start a hold', () => {
    vi.useFakeTimers();
    bubble(mk());
    fireEvent.pointerDown(screen.getByTestId('bub'), { pointerType: 'mouse' });
    act(() => { vi.advanceTimersByTime(700); });
    expect(screen.queryByRole('menu')).toBeNull();
  });
  test('an active text selection suppresses the touch menu', () => {
    vi.useFakeTimers();
    bubble(mk());
    vi.spyOn(window, 'getSelection').mockReturnValue({ isCollapsed: false, toString: () => 'sel' });
    fireEvent.pointerDown(screen.getByTestId('bub'), { pointerType: 'touch', clientX: 0, clientY: 0 });
    act(() => { vi.advanceTimersByTime(600); });
    expect(screen.queryByRole('menu')).toBeNull();
  });
});
