// Task 20261011-web-session-screenshare-rooms testing: pure screen-share rules.
import { describe, test, expect, afterEach, vi } from 'vitest';
import {
  SCREEN_SHARE_FLAG, contentOwnerId, isDisplayCaptureSupported, canOfferScreenShare,
  screenShareStartBlock, classifyCaptureError, callLayoutMode, contentAreaKind, SCREEN_SHARE_COPY,
} from './screenShareState.js';

afterEach(() => vi.unstubAllGlobals());

describe('screenShareState', () => {
  test('flag name matches the server flag', () => {
    expect(SCREEN_SHARE_FLAG).toBe('screen_share_enabled');
  });
  test('contentOwnerId strips #content and never fabricates', () => {
    expect(contentOwnerId('u1#content')).toBe('u1');
    expect(contentOwnerId('u1')).toBe('u1');
    expect(contentOwnerId('')).toBe('');
    expect(contentOwnerId(null)).toBe('');
    expect(contentOwnerId(42)).toBe('');
  });
  test('capture support detection', () => {
    vi.stubGlobal('navigator', { mediaDevices: { getDisplayMedia: () => {} } });
    expect(isDisplayCaptureSupported()).toBe(true);
    vi.stubGlobal('navigator', { mediaDevices: {} });
    expect(isDisplayCaptureSupported()).toBe(false);
    vi.stubGlobal('navigator', {});
    expect(isDisplayCaptureSupported()).toBe(false);
  });
  test('offer fails closed unless flag === true and supported === true', () => {
    expect(canOfferScreenShare({ flagEnabled: true, supported: true })).toBe(true);
    for (const flagEnabled of [false, undefined, null, 'true', 1]) {
      expect(canOfferScreenShare({ flagEnabled, supported: true })).toBe(false);
    }
    expect(canOfferScreenShare({ flagEnabled: true, supported: false })).toBe(false);
    expect(canOfferScreenShare({ flagEnabled: true })).toBe(false);
  });
  test('start block reasons in precedence order', () => {
    const ok = { flagEnabled: true, supported: true, connected: true, someoneElseSharing: false, phase: 'idle' };
    expect(screenShareStartBlock(ok)).toBeNull();
    expect(screenShareStartBlock({ ...ok, flagEnabled: false })).toBe('flagOff');
    expect(screenShareStartBlock({ ...ok, supported: false })).toBe('unsupported');
    expect(screenShareStartBlock({ ...ok, connected: false })).toBe('notConnected');
    expect(screenShareStartBlock({ ...ok, phase: 'sharing' })).toBe('alreadyActive');
    expect(screenShareStartBlock({ ...ok, someoneElseSharing: true })).toBe('someoneElseSharing');
  });
  test('capture error classification', () => {
    expect(classifyCaptureError({ name: 'NotAllowedError' })).toBe('cancelled');
    expect(classifyCaptureError({ name: 'AbortError' })).toBe('cancelled');
    expect(classifyCaptureError({ name: 'NotReadableError' })).toBe('failed');
    expect(classifyCaptureError(null)).toBe('failed');
  });
  test('layout: top row iff prompts open or a share exists', () => {
    expect(callLayoutMode({ promptsOpen: false, hasShare: false })).toBe('field');
    expect(callLayoutMode({ promptsOpen: true, hasShare: false })).toBe('row');
    expect(callLayoutMode({ promptsOpen: false, hasShare: true })).toBe('row');
  });
  test('share wins content area over Prompts; Prompts return when share stops', () => {
    expect(contentAreaKind({ promptsOpen: true, hasRemoteShare: true, sharingSelf: false })).toBe('remoteShare');
    expect(contentAreaKind({ promptsOpen: true, hasRemoteShare: false, sharingSelf: true })).toBe('selfShare');
    expect(contentAreaKind({ promptsOpen: true, hasRemoteShare: false, sharingSelf: false })).toBe('prompts');
    expect(contentAreaKind({ promptsOpen: false, hasRemoteShare: false, sharingSelf: false })).toBe('none');
  });
  test('copy never contains raw error text placeholders', () => {
    for (const v of Object.values(SCREEN_SHARE_COPY)) expect(typeof v).toBe('string');
  });
});
