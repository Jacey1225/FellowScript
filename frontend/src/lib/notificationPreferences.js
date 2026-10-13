// Task 20261012-notification-settings. Client for GET/PUT
// /notification/{user_id}/push-preferences (flat {key: bool} map, default on).
// Throws on any failure; never fabricates a value the server did not confirm.
import { API } from '../config.js';

// Toggleable push types, in display order. `flag` is the /app/capabilities
// feature that must be on for the type to be shown (null = always shown).
// Essential pushes (incoming call ring, join-request approval) are not here:
// the server never lets them be switched off.
export const PUSH_TYPE_GROUPS = [
  {
    title: 'Chat',
    types: [
      { key: 'messages', label: 'Messages', description: 'New chat messages and thread replies.', flag: null },
      { key: 'pins', label: 'Pinned messages', description: 'When someone pins a message.', flag: 'message_pins' },
      { key: 'reactions', label: 'Reactions', description: 'When someone reacts to your message.', flag: 'message_reaction_push' },
      { key: 'announcements', label: 'Announcements', description: 'Group announcements, including heads-ups before they publish.', flag: null },
    ],
  },
  {
    title: 'Groups and sessions',
    types: [
      { key: 'session_reminders', label: 'Session reminders', description: 'New sessions and sessions that are starting.', flag: null },
      { key: 'join_requests', label: 'Join requests', description: 'When someone asks to join a group you own.', flag: 'join_request_push' },
    ],
  },
  {
    title: 'Friends and reminders',
    types: [
      { key: 'friend_highlight', label: 'Friend highlights', description: 'When a friend highlights a verse.', flag: 'friend_highlight_push' },
      { key: 'friend_activity', label: 'Friend activity', description: 'When a friend is active again, and friend nudges.', flag: null },
      { key: 'reminders', label: 'Gentle reminders', description: 'Daily nudges and your scheduled devotion events.', flag: null },
    ],
  },
];

// Groups with capability-gated types removed (and empty groups dropped).
export function visibleGroups(isEnabled) {
  return PUSH_TYPE_GROUPS
    .map((g) => ({ ...g, types: g.types.filter((t) => !t.flag || isEnabled(t.flag)) }))
    .filter((g) => g.types.length > 0);
}

const url = (userId) => `${API}/notification/${encodeURIComponent(userId)}/push-preferences`;

function parseMap(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return null;
  const out = {};
  for (const g of PUSH_TYPE_GROUPS) {
    for (const t of g.types) {
      if (typeof body[t.key] !== 'boolean') return null;
      out[t.key] = body[t.key];
    }
  }
  return out;
}

export async function fetchPushPreferences(userId) {
  const res = await fetch(url(userId));
  if (!res.ok) throw new Error('load failed');
  const map = parseMap(await res.json());
  if (!map) throw new Error('malformed preferences');
  return map;
}

export async function savePushPreference(userId, key, enabled) {
  const res = await fetch(url(userId), {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ [key]: enabled }),
  });
  if (!res.ok) throw new Error('save failed');
  const map = parseMap(await res.json());
  if (!map) throw new Error('malformed preferences');
  return map;
}
