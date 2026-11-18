import { describe, test, expect } from 'vitest';
import { frameBelongsToContact as ok } from './chatFrameBelongs.js';

const DM_A = { id: 'a', type: 'friend', toUsers: ['a'] };
const HUB = { id: 'g1', type: 'group', group_id: 'g1', toUsers: ['u1', 'a'] };

describe('frameBelongsToContact', () => {
  test('DM frame is rejected in an open group (the Hub bug)', () => {
    expect(ok({ from_user: 'a', group_id: '' }, HUB)).toBe(false);
    expect(ok({ from_user: 'a' }, HUB)).toBe(false);
  });
  test('group frame for another group is rejected in group and DM views', () => {
    expect(ok({ from_user: 'a', group_id: 'g2' }, HUB)).toBe(false);
    expect(ok({ from_user: 'a', group_id: 'g1' }, DM_A)).toBe(false);
  });
  test('DM frame from another friend is rejected in a DM', () => {
    expect(ok({ from_user: 'b', group_id: '' }, DM_A)).toBe(false);
  });
  test('matching frames are accepted', () => {
    expect(ok({ from_user: 'a', group_id: '' }, DM_A)).toBe(true);
    expect(ok({ from_user: 'a' }, DM_A)).toBe(true);
    expect(ok({ from_user: 'z', group_id: 'G1' }, HUB)).toBe(true);
  });
  test('group contact without group_id field still matches by id', () => {
    expect(ok({ from_user: 'a', group_id: 'g1' }, { id: 'g1', type: 'group' })).toBe(true);
    expect(ok({ from_user: 'a', group_id: '' }, { id: 'g1', type: 'group' })).toBe(false);
  });
  test('missing contact or frame fails closed', () => {
    expect(ok({ from_user: 'a' }, null)).toBe(false);
    expect(ok(null, DM_A)).toBe(false);
  });
});
