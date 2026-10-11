// Task 20261011-desktop-chat-replies-reactions: reaction_emoji allowlist parsing, fail closed.
import { describe, test, expect } from 'vitest';
import { parseCapabilities, CAPABILITIES_OFF } from './capabilities.js';

const base = { features: { message_reactions: true, chat_replies: true }, terms_current: true };
const EMPTY = { quick: [], more: [] };

describe('reaction_emoji', () => {
  test('valid allowlist kept; more de-duplicated against quick', () => {
    const c = parseCapabilities({ ...base, reaction_emoji: { quick: ['👍', '❤️'], more: ['👍', '🔥', '🔥'] } });
    expect(c.reactionEmoji).toEqual({ quick: ['👍', '❤️'], more: ['🔥'] });
    expect(c.features.message_reactions).toBe(true);
    expect(c.features.chat_replies).toBe(true);
  });
  test.each([
    ['absent', undefined],
    ['null', null],
    ['array', ['👍']],
    ['string', '👍'],
    ['quick not array', { quick: '👍', more: [] }],
    ['more missing', { quick: ['👍'] }],
    ['non-string member', { quick: ['👍', 5], more: [] }],
    ['empty-string member', { quick: [''], more: [] }],
  ])('malformed (%s) -> empty allowlist, rest of body still parsed', (_n, v) => {
    const c = parseCapabilities({ ...base, reaction_emoji: v });
    expect(c.reactionEmoji).toEqual(EMPTY);
    expect(c.termsCurrent).toBe(true);
  });
  test('CAPABILITIES_OFF has an empty allowlist and no flags', () => {
    expect(CAPABILITIES_OFF.reactionEmoji.quick).toEqual([]);
    expect(CAPABILITIES_OFF.reactionEmoji.more).toEqual([]);
    expect(CAPABILITIES_OFF.features.message_reactions).toBeUndefined();
  });
  test('non-true flag values stay false', () => {
    const c = parseCapabilities({ ...base, features: { message_reactions: 'true', chat_replies: 1 } });
    expect(c.features.message_reactions).toBe(false);
    expect(c.features.chat_replies).toBe(false);
  });
});
