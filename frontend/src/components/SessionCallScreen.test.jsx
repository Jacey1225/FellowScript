// Task 20261011-web-session-ui-parity testing: joined-state call screen.
// Run: cd frontend && npx vitest run src/components/SessionCallScreen.test.jsx
import React from 'react';
import { describe, test, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, within } from '@testing-library/react';
import SessionCallScreen, { resolveName, PromptsPanel } from './SessionCallScreen.jsx';

afterEach(cleanup);

const user = { user_id: 'me', username: 'Me' };
const friends = [{ id: 'f1', name: 'Fran' }];
const base = (over = {}) => ({
  session: { participants: ['f1', 'me', 'stranger-uuid-1234'], prompts: ['First?', 'Second?'] },
  user, friends, fetchedNames: {}, talkingUserId: null,
  muted: false, onToggleMute: vi.fn(), videoEnabled: false, onToggleVideo: vi.fn(),
  canRing: true, onRing: vi.fn(), onLeave: vi.fn(), ...over,
});
const mount = (over) => { const p = base(over); return { p, ...render(<SessionCallScreen {...p} />) }; };

describe('resolveName', () => {
  test('self, friend, fetched, unknown -> null (never a raw id)', () => {
    const ctx = { user, friends, fetched: { x: 'Xavier' } };
    expect(resolveName('me', ctx)).toBe('Me');
    expect(resolveName('f1', ctx)).toBe('Fran');
    expect(resolveName('x', ctx)).toBe('Xavier');
    expect(resolveName('stranger', ctx)).toBeNull();
    expect(resolveName(null, ctx)).toBeNull();
  });
});

describe('SessionCallScreen', () => {
  test('own bubble first labelled You; unknown shows glyph, no raw id', () => {
    const { container } = mount();
    const names = [...container.querySelectorAll('.call-bubble-name')].map(n => n.textContent);
    expect(names).toEqual(['You', 'Fran', 'Member']);
    expect(container.textContent).not.toContain('stranger-uuid');
  });

  test('scattered layout by default; top row when Prompts open', () => {
    const { container } = mount();
    expect(container.querySelector('.call-bubbles-scatter')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Interactions' }));
    fireEvent.click(screen.getByRole('menuitem', { name: /Prompts/ }));
    expect(container.querySelector('.call-bubbles-row')).toBeTruthy();
    expect(container.querySelector('.call-bubbles-scatter')).toBeNull();
    expect(screen.getByRole('region', { name: 'Discussion prompts' })).toBeTruthy();
  });

  test('End call uses the leave path', () => {
    const { p } = mount();
    fireEvent.click(screen.getByRole('button', { name: 'End call' }));
    expect(p.onLeave).toHaveBeenCalledTimes(1);
  });

  test('menu has Ring/Prompts/Camera/Mute and never a Share screen row', () => {
    mount();
    fireEvent.click(screen.getByRole('button', { name: 'Interactions' }));
    const labels = screen.getAllByRole('menuitem').map(i => i.textContent);
    expect(labels).toEqual(['Ring', 'Prompts', 'Turn on camera', 'Mute']);
    expect(screen.queryByText(/share screen/i)).toBeNull();
  });

  test('Ring row hidden when canRing is false', () => {
    mount({ canRing: false });
    fireEvent.click(screen.getByRole('button', { name: 'Interactions' }));
    expect(screen.queryByRole('menuitem', { name: 'Ring' })).toBeNull();
  });

  test('Escape closes menu and returns focus to the Interactions button', () => {
    mount();
    const btn = screen.getByRole('button', { name: 'Interactions' });
    fireEvent.click(btn);
    expect(btn.getAttribute('aria-expanded')).toBe('true');
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(screen.queryByRole('menu')).toBeNull();
    expect(document.activeElement).toBe(btn);
  });

  test('Mute item calls onToggleMute and closes menu; muted state shows badge and label', () => {
    const { p } = mount();
    fireEvent.click(screen.getByRole('button', { name: 'Interactions' }));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Mute' }));
    expect(p.onToggleMute).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole('menu')).toBeNull();
    cleanup();
    const { container } = mount({ muted: true });
    expect(container.querySelector('.call-muted-badge')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Interactions, muted' })).toBeTruthy();
  });

  test('ellipsis becomes close icon while open (aria-expanded)', () => {
    mount();
    const btn = screen.getByRole('button', { name: 'Interactions' });
    expect(btn.querySelector('.anticon-ellipsis')).toBeTruthy();
    fireEvent.click(btn);
    expect(btn.querySelector('.anticon-close')).toBeTruthy();
  });
});

describe('PromptsPanel', () => {
  test('untitled, numbered cards with local-only emphasis toggle', () => {
    const { container } = render(<PromptsPanel prompts={['A', 'B']} onClose={() => {}} />);
    expect(container.querySelector('h1,h2,h3,h4')).toBeNull();
    const cards = within(container).getAllByRole('button', { pressed: false });
    expect(cards.map(c => c.querySelector('.call-prompt-num').textContent)).toEqual(['1', '2']);
    expect(cards[0].getAttribute('aria-pressed')).toBe('false');
    fireEvent.click(cards[0]);
    expect(cards[0].getAttribute('aria-pressed')).toBe('true');
    expect(cards[1].getAttribute('aria-pressed')).toBe('false');
    fireEvent.click(cards[0]);
    expect(cards[0].getAttribute('aria-pressed')).toBe('false');
  });

  test('empty state and close button', () => {
    const onClose = vi.fn();
    render(<PromptsPanel prompts={[]} onClose={onClose} />);
    expect(screen.getByText(/No prompts/)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Close prompts' }));
    expect(onClose).toHaveBeenCalled();
  });
});
