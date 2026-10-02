// Task 20261001-chat-pagination step 8: ChatThread paging UI (scroll anchoring
// by message id, 'New messages' pill, retry, aria-live, reduced motion).
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import ChatThread from './ChatThread.jsx';

const CONTACT = { id: 'c1', name: 'Ada', type: 'friend' };
const USER = { user_id: 'u1', username: 'me' };
const msg = (id, extra = {}) => ({ id, key: id, text: `text-${id}`, mine: false, sender: 'ada', timestamp: '2026-10-01T10:00:00Z', ...extra });
const PAGED = { paged: true, hasMore: true, loading: false, error: false, loadedCount: 0, loadedTick: 0 };

let tops; // id -> top px (relative to the page)
let scrollIntoView;
let reduced;

beforeEach(() => {
  tops = {};
  reduced = false;
  scrollIntoView = vi.fn();
  Element.prototype.scrollIntoView = scrollIntoView;
  window.matchMedia = vi.fn(() => ({ get matches() { return reduced; }, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }));
  vi.spyOn(Element.prototype, 'getBoundingClientRect').mockImplementation(function () {
    const id = this.getAttribute && this.getAttribute('data-msg-id');
    const top = id ? (tops[id] ?? 0) : 0;
    return { top, bottom: top + 40, left: 0, right: 100, width: 100, height: 40, x: 0, y: top };
  });
});
afterEach(() => { cleanup(); vi.restoreAllMocks(); });

function element(props) {
  return (
    <ChatThread
      contact={CONTACT} messages={[]} groupMembers={[]} user={USER}
      onBack={vi.fn()} onSend={vi.fn()} sessions={[]} activeSessionId={null} talkingUserId={null}
      onJoinSession={vi.fn()} onLeaveSession={vi.fn()} onOpenSessionCreator={vi.fn()}
      onEditSession={vi.fn()} onDeleteSession={vi.fn()} onNavigateVerse={vi.fn()}
      videoEnabled={false} videoTiles={{}} onToggleVideo={vi.fn()} bindVideoTile={vi.fn()}
      {...props}
    />
  );
}
// Mirrors openChat: the thread mounts empty, then the first page lands.
function openLoaded(messages, props = {}) {
  const utils = render(element({ messages: [], ...props }));
  utils.rerender(element({ messages, ...props }));
  return utils;
}
const scrollerOf = (container) => container.querySelector('[data-msg-id]').parentElement;
function geometry(sc, { scrollTop = 0, scrollHeight = 2000, clientHeight = 500 } = {}) {
  let st = scrollTop;
  Object.defineProperty(sc, 'scrollTop', { configurable: true, get: () => st, set: (v) => { st = v; } });
  Object.defineProperty(sc, 'scrollHeight', { configurable: true, get: () => scrollHeight });
  Object.defineProperty(sc, 'clientHeight', { configurable: true, get: () => clientHeight });
  return () => st;
}

describe('scroll anchoring by id', () => {
  test('prepending an older page keeps the first visible message at the same offset', () => {
    const onLoadOlder = vi.fn();
    tops = { m3: 10, m4: 60 };
    const { container, rerender } = openLoaded([msg('m3'), msg('m4')], { olderPage: PAGED, onLoadOlder });
    const sc = scrollerOf(container);
    const getTop = geometry(sc, { scrollTop: 50 });
    onLoadOlder.mockClear();
    fireEvent.scroll(sc);
    expect(onLoadOlder).toHaveBeenCalledTimes(1);
    // older page lands: m3 is pushed down by 300px
    tops = { m1: 10, m2: 160, m3: 310, m4: 360 };
    rerender(element({ messages: [msg('m1'), msg('m2'), msg('m3'), msg('m4')], olderPage: { ...PAGED, loading: false, loadedCount: 2, loadedTick: 1 }, onLoadOlder }));
    expect(getTop()).toBe(50 + 300);
  });

  test('no scroll-to-bottom when older messages are prepended', () => {
    const onLoadOlder = vi.fn();
    tops = { m3: 10 };
    const { container, rerender } = openLoaded([msg('m3')], { olderPage: PAGED, onLoadOlder });
    const sc = scrollerOf(container);
    geometry(sc, { scrollTop: 50 });
    scrollIntoView.mockClear();
    fireEvent.scroll(sc);
    tops = { m2: 10, m3: 110 };
    rerender(element({ messages: [msg('m2'), msg('m3')], olderPage: { ...PAGED, loadedTick: 1, loadedCount: 1 }, onLoadOlder }));
    expect(scrollIntoView).not.toHaveBeenCalled();
  });

  test('scrolling away from the top does not request older', () => {
    const onLoadOlder = vi.fn();
    const { container } = openLoaded([msg('m3')], { olderPage: PAGED, onLoadOlder });
    const sc = scrollerOf(container);
    geometry(sc, { scrollTop: 600 });
    onLoadOlder.mockClear();
    fireEvent.scroll(sc);
    expect(onLoadOlder).not.toHaveBeenCalled();
  });

  test('not requested while loading, at the start, or when not paged', () => {
    for (const op of [{ ...PAGED, loading: true }, { ...PAGED, hasMore: false }, undefined]) {
      const onLoadOlder = vi.fn();
      const { container, unmount } = render(element({ messages: [msg('m3')], olderPage: op, onLoadOlder }));
      const sc = scrollerOf(container);
      geometry(sc, { scrollTop: 0 });
      fireEvent.scroll(sc);
      expect(onLoadOlder).not.toHaveBeenCalled();
      unmount();
    }
  });

  test('messages render with data-msg-id from their stable key', () => {
    const { container } = render(element({ messages: [msg('m3'), msg('m4')], olderPage: PAGED }));
    expect(Array.from(container.querySelectorAll('[data-msg-id]')).map(e => e.getAttribute('data-msg-id'))).toEqual(['m3', 'm4']);
  });
});

describe('auto-scroll and New messages pill', () => {
  test('first load scrolls to the newest message instantly', () => {
    render(element({ messages: [msg('a'), msg('b')], olderPage: PAGED }));
    expect(scrollIntoView).toHaveBeenCalledWith({ behavior: 'auto' });
  });

  test('live message while scrolled up shows the pill instead of scrolling; click jumps and hides', () => {
    const { container, rerender } = openLoaded([msg('a'), msg('b')], { olderPage: PAGED });
    const sc = scrollerOf(container);
    geometry(sc, { scrollTop: 300, scrollHeight: 2000, clientHeight: 500 });
    fireEvent.scroll(sc); // far from bottom; scrollTop 300 >= 120 so no older request
    scrollIntoView.mockClear();
    rerender(element({ messages: [msg('a'), msg('b'), msg('c')], olderPage: PAGED }));
    expect(scrollIntoView).not.toHaveBeenCalled();
    const pill = screen.getByText('New messages');
    fireEvent.click(pill);
    expect(scrollIntoView).toHaveBeenCalledTimes(1);
    expect(screen.queryByText('New messages')).toBeNull();
  });

  test('live message while near the bottom auto-scrolls, no pill', () => {
    const { container, rerender } = openLoaded([msg('a')], { olderPage: PAGED });
    const sc = scrollerOf(container);
    geometry(sc, { scrollTop: 1450, scrollHeight: 2000, clientHeight: 500 });
    fireEvent.scroll(sc);
    scrollIntoView.mockClear();
    rerender(element({ messages: [msg('a'), msg('b')], olderPage: PAGED }));
    expect(scrollIntoView).toHaveBeenCalled();
    expect(screen.queryByText('New messages')).toBeNull();
  });

  test('own send scrolls even when scrolled up', () => {
    const { container, rerender } = openLoaded([msg('a')], { olderPage: PAGED });
    const sc = scrollerOf(container);
    geometry(sc, { scrollTop: 300 });
    fireEvent.scroll(sc);
    scrollIntoView.mockClear();
    rerender(element({ messages: [msg('a'), { key: 'c:r', clientRef: 'r', pending: true, text: 'mine', mine: true, timestamp: '2026-10-01T10:00:05Z' }], olderPage: PAGED }));
    expect(scrollIntoView).toHaveBeenCalled();
    expect(screen.queryByText('New messages')).toBeNull();
  });

  test('reduced motion: jump uses auto, otherwise smooth', () => {
    const run = () => {
      const { container, rerender, unmount } = openLoaded([msg('a'), msg('b')], { olderPage: PAGED });
      const sc = scrollerOf(container);
      geometry(sc, { scrollTop: 300 });
      fireEvent.scroll(sc);
      rerender(element({ messages: [msg('a'), msg('b'), msg('c')], olderPage: PAGED }));
      scrollIntoView.mockClear();
      fireEvent.click(screen.getByText('New messages'));
      const arg = scrollIntoView.mock.calls[0][0];
      unmount();
      return arg;
    };
    reduced = true;
    expect(run()).toEqual({ behavior: 'auto' });
    reduced = false;
    expect(run()).toEqual({ behavior: 'smooth' });
  });
});

describe('indicators, retry and announcements', () => {
  test('loading spinner shown while loading', () => {
    render(element({ messages: [msg('a')], olderPage: { ...PAGED, loading: true } }));
    expect(screen.getByLabelText('Loading earlier messages')).toBeTruthy();
  });

  test('error shows a Retry that calls the loader', () => {
    const onLoadOlder = vi.fn();
    const { container } = render(element({ messages: [msg('a')], olderPage: { ...PAGED, error: true }, onLoadOlder }));
    const btn = screen.getByText(/Couldn't load earlier messages/);
    // the auto "short content" effect must not fire while in the error state
    expect(onLoadOlder).not.toHaveBeenCalled();
    fireEvent.click(btn);
    expect(onLoadOlder).toHaveBeenCalledTimes(1);
    expect(container).toBeTruthy();
  });

  test('start-of-conversation marker only when paged and no more', () => {
    const { unmount } = render(element({ messages: [msg('a')], olderPage: { ...PAGED, hasMore: false } }));
    expect(screen.getByText('Start of conversation')).toBeTruthy();
    unmount();
    render(element({ messages: [msg('a')], olderPage: { ...PAGED, hasMore: true } }));
    expect(screen.queryByText('Start of conversation')).toBeNull();
  });

  test('legacy thread (no olderPage): no marker, spinner, pill or aria-live text', () => {
    render(element({ messages: [msg('a')] }));
    expect(screen.queryByText('Start of conversation')).toBeNull();
    expect(screen.queryByLabelText('Loading earlier messages')).toBeNull();
    expect(screen.getByRole('status').textContent).toBe('');
  });

  test('aria-live polite region announces loaded earlier messages with plural handling', () => {
    const { rerender } = render(element({ messages: [msg('a')], olderPage: PAGED }));
    const region = screen.getByRole('status');
    expect(region.getAttribute('aria-live')).toBe('polite');
    expect(region.textContent).toBe('');
    rerender(element({ messages: [msg('z'), msg('a')], olderPage: { ...PAGED, loadedCount: 1, loadedTick: 1 } }));
    expect(region.textContent).toBe('1 earlier message loaded');
    rerender(element({ messages: [msg('y'), msg('z'), msg('a')], olderPage: { ...PAGED, loadedCount: 30, loadedTick: 2 } }));
    expect(region.textContent).toBe('30 earlier messages loaded');
  });
});
