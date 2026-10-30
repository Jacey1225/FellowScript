// Task 20261030-user-profiles testing step 8: deferred unfriend grace period.
import React from 'react';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useDeferredAction } from './useDeferredAction.js';

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

describe('useDeferredAction', () => {
  test('commits after the delay', () => {
    const { result } = renderHook(() => useDeferredAction(6000));
    const commit = vi.fn();
    act(() => result.current.start(commit));
    act(() => vi.advanceTimersByTime(5999));
    expect(commit).not.toHaveBeenCalled();
    act(() => vi.advanceTimersByTime(2));
    expect(commit).toHaveBeenCalledTimes(1);
  });

  test('undo before the delay cancels the commit and reports true', () => {
    const { result } = renderHook(() => useDeferredAction(6000));
    const commit = vi.fn();
    act(() => result.current.start(commit));
    let undone;
    act(() => { undone = result.current.undo(); });
    act(() => vi.advanceTimersByTime(10000));
    expect(undone).toBe(true);
    expect(commit).not.toHaveBeenCalled();
  });

  test('undo with nothing pending reports false (and after commit too)', () => {
    const { result } = renderHook(() => useDeferredAction(6000));
    expect(result.current.undo()).toBe(false);
    act(() => result.current.start(vi.fn()));
    act(() => vi.advanceTimersByTime(6001));
    expect(result.current.undo()).toBe(false);
  });

  test('unmount (leaving the screen) commits immediately, exactly once', () => {
    const { result, unmount } = renderHook(() => useDeferredAction(6000));
    const commit = vi.fn();
    act(() => result.current.start(commit));
    unmount();
    expect(commit).toHaveBeenCalledTimes(1);
    act(() => vi.advanceTimersByTime(10000));
    expect(commit).toHaveBeenCalledTimes(1);
  });

  test('unmount after undo does not commit', () => {
    const { result, unmount } = renderHook(() => useDeferredAction(6000));
    const commit = vi.fn();
    act(() => result.current.start(commit));
    act(() => { result.current.undo(); });
    unmount();
    expect(commit).not.toHaveBeenCalled();
  });

  test('starting a second action flushes the first', () => {
    const { result } = renderHook(() => useDeferredAction(6000));
    const first = vi.fn(); const second = vi.fn();
    act(() => result.current.start(first));
    act(() => result.current.start(second));
    expect(first).toHaveBeenCalledTimes(1);
    expect(second).not.toHaveBeenCalled();
  });
});
