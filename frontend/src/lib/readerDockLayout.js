// Default layout + persistence constants for the desktop Reader dockview
// workspace. buildDefaultLayout is the single source of truth for "the
// default arrangement" — used both on first-ever visit and by the Reset
// Layout button, so there's no separate hand-written JSON blob to keep in
// sync with it.

export const PANEL_IDS = {
  BIBLE:      'bible-reader',
  NOTES:      'notes',
  HIGHLIGHTS: 'highlights',
  MESSAGING:  'messaging',
  AGENT_CHAT: 'agent-chat',
};

// Per-user persistence (20261011-reader-tab-drag-docks). The record lives under
// `fs_reader_layout_v2:<userId|guest>` so one browser profile keeps a separate
// arrangement per account. The legacy global v1 key is deliberately never read:
// it has no owner, so applying it to a named user could leak another account's
// arrangement (fail closed).
export const LAYOUT_STORAGE_PREFIX = 'fs_reader_layout_v2';
export const LEGACY_LAYOUT_STORAGE_KEY = 'fs_reader_layout_v1';
export const LAYOUT_VERSION = 2;
export const GUEST_LAYOUT_USER = 'guest';

const USER_ID_RE = /^[A-Za-z0-9_-]{1,128}$/;
const DOCK_SIDES = ['left', 'right', 'top', 'bottom'];
const SIDE_TO_DIRECTION = { left: 'left', right: 'right', top: 'above', bottom: 'below' };
const ALL_PANEL_IDS = Object.values(PANEL_IDS);

/** Storage key for a user id; anything missing or unsafe maps to the guest key. */
export function layoutStorageKey(userId) {
  const id = userId == null ? '' : String(userId);
  return `${LAYOUT_STORAGE_PREFIX}:${USER_ID_RE.test(id) ? id : GUEST_LAYOUT_USER}`;
}

// Kept for callers that only know the signed-out/guest record.
export const LAYOUT_STORAGE_KEY = layoutStorageKey(null);

// Display titles per panel id — kept alongside PANEL_IDS (rather than only
// inline in buildDefaultLayout's addPanel calls) so the left dock rail
// (20260825-reader-dock-rail-polish, item 3) can label/tooltip its icons
// from the same source of truth instead of re-hardcoding these strings.
export const PANEL_TITLES = {
  [PANEL_IDS.BIBLE]:      'Bible',
  [PANEL_IDS.NOTES]:      'Notes',
  [PANEL_IDS.HIGHLIGHTS]: 'Highlights',
  [PANEL_IDS.MESSAGING]:  'Messages',
  [PANEL_IDS.AGENT_CHAT]: 'Agent Chat',
};

/**
 * Builds the default layout on a dockview api:
 *   - Bible reader fills the main/left area.
 *   - Notes + Highlights + Messaging are grouped as tabs on the right,
 *     spanning the full height (a VSCode-style sidebar).
 *   - Agent Chat is docked below the Bible reader only (a VSCode-style
 *     integrated terminal), NOT under the right column.
 *
 * Ordering is load-bearing: the right-hand tab group must be added BEFORE
 * splitting Agent Chat below the Bible reader, or Agent Chat would stretch
 * under both columns instead of just the reader.
 */
export function buildDefaultLayout(api) {
  api.addPanel({ id: PANEL_IDS.BIBLE, component: PANEL_IDS.BIBLE, title: 'Bible' });

  api.addPanel({
    id: PANEL_IDS.NOTES, component: PANEL_IDS.NOTES, title: 'Notes',
    position: { direction: 'right', referencePanel: PANEL_IDS.BIBLE },
    initialWidth: 420,
  });
  api.addPanel({
    id: PANEL_IDS.HIGHLIGHTS, component: PANEL_IDS.HIGHLIGHTS, title: 'Highlights',
    position: { direction: 'within', referencePanel: PANEL_IDS.NOTES },
    inactive: true, renderer: 'always',
  });
  api.addPanel({
    id: PANEL_IDS.MESSAGING, component: PANEL_IDS.MESSAGING, title: 'Messages',
    position: { direction: 'within', referencePanel: PANEL_IDS.NOTES },
    inactive: true, renderer: 'always',
  });

  api.addPanel({
    id: PANEL_IDS.AGENT_CHAT, component: PANEL_IDS.AGENT_CHAT, title: 'Agent Chat',
    position: { direction: 'below', referencePanel: PANEL_IDS.BIBLE },
    initialHeight: 260,
  });

  api.getPanel(PANEL_IDS.NOTES)?.api.setActive();
  api.getPanel(PANEL_IDS.BIBLE)?.api.setActive();
}

const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

/**
 * Saved layout is untrusted input: only accept dockview JSON whose panels are
 * exactly known Reader panels. Closed panels are legitimate (the rail reopens
 * them), so a subset is fine; an empty/unknown set is not.
 */
export function isValidSavedLayout(layout) {
  if (!isPlainObject(layout) || !isPlainObject(layout.grid) || !isPlainObject(layout.panels)) return false;
  const ids = Object.keys(layout.panels);
  if (ids.length === 0) return false;
  return ids.every((id) => {
    const p = layout.panels[id];
    return ALL_PANEL_IDS.includes(id) && isPlainObject(p) && p.id === id && p.contentComponent === id;
  });
}

function sanitizeLastDock(raw) {
  const out = {};
  if (!isPlainObject(raw)) return out;
  for (const id of ALL_PANEL_IDS) {
    const e = raw[id];
    if (!isPlainObject(e)) continue;
    const side = DOCK_SIDES.includes(e.side) ? e.side : null;
    const tabmates = Array.isArray(e.tabmates)
      ? e.tabmates.filter((t) => ALL_PANEL_IDS.includes(t) && t !== id)
      : [];
    if (side || tabmates.length) out[id] = { side, tabmates };
  }
  return out;
}

function readRecord(userId) {
  try {
    const raw = localStorage.getItem(layoutStorageKey(userId));
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    if (!isPlainObject(parsed) || parsed.version !== LAYOUT_VERSION) return null;
    return parsed;
  } catch {
    return null;
  }
}

/** Last-known dock per panel id for this user ({} when none/invalid). */
export function loadLastDock(userId) {
  return sanitizeLastDock(readRecord(userId)?.lastDock);
}

/**
 * Where a panel currently lives: the other panels tabbed with it, and (for a
 * panel alone in its group) which grid edge its group touches. Edge detection
 * uses live group rects; when layout has no size (e.g. jsdom) side stays null
 * and reopen falls back to the default position.
 */
function describeDock(api, panel) {
  const group = panel.group;
  const tabmates = (group?.panels || []).map((p) => p.id).filter((pid) => pid !== panel.id);
  let side = null;
  try {
    const rects = api.groups.map((g) => g.element.getBoundingClientRect());
    const r = group.element.getBoundingClientRect();
    const minL = Math.min(...rects.map((x) => x.left));
    const maxR = Math.max(...rects.map((x) => x.right));
    const minT = Math.min(...rects.map((x) => x.top));
    const maxB = Math.max(...rects.map((x) => x.bottom));
    const spansW = r.width >= (maxR - minL) - 2;
    const spansH = r.height >= (maxB - minT) - 2;
    if (maxR - minL > 0 && maxB - minT > 0 && api.groups.length > 1) {
      if (spansH && !spansW) side = r.left <= minL + 2 ? 'left' : (r.right >= maxR - 2 ? 'right' : null);
      else if (spansW && !spansH) side = r.bottom >= maxB - 2 ? 'bottom' : (r.top <= minT + 2 ? 'top' : null);
    }
  } catch {}
  return { side, tabmates };
}

function writeRecord(api, userId, lastDock) {
  try {
    localStorage.setItem(
      layoutStorageKey(userId),
      JSON.stringify({ version: LAYOUT_VERSION, layout: api.toJSON(), lastDock }),
    );
  } catch {}
}

/**
 * Restores this user's saved layout. Returns false (caller builds the default)
 * on anything missing, stale, corrupt, or failing validation; a half-applied
 * fromJSON is cleared first so the default builds on an empty api.
 */
export function loadSavedLayout(api, userId) {
  try {
    const parsed = readRecord(userId);
    if (!parsed || !isValidSavedLayout(parsed.layout)) return false;
    try {
      api.fromJSON(parsed.layout);
    } catch {
      try { api.clear(); } catch {}
      return false;
    }
    return true;
  } catch {
    return false;
  }
}

/**
 * Saves the live layout. lastDock entries for panels still open are refreshed;
 * entries for closed panels are carried over from the previous record so
 * reopenPanel can send them back where they were.
 */
export function saveLayout(api, userId) {
  const lastDock = loadLastDock(userId);
  for (const panel of api.panels) lastDock[panel.id] = describeDock(api, panel);
  writeRecord(api, userId, lastDock);
}

export function resetLayout(api, userId) {
  api.clear();
  buildDefaultLayout(api);
  writeRecord(api, userId, {});
}

/**
 * Re-adds a currently-closed panel to the live layout in a sensible default
 * position (left dock rail's click-to-reopen, 20260825-reader-dock-rail-polish
 * item 3) — reuses buildDefaultLayout's own per-panel position rules as the
 * reference for where each panel "belongs" (Notes/Highlights/Messaging tab
 * together to the right of Bible; Agent Chat docks below Bible) rather than
 * inventing new placement logic. Falls back to an unpositioned addPanel (a
 * new top-level group) when none of a panel's usual reference panels happen
 * to be open too — e.g. reopening Bible when every other panel is also
 * closed. No-op if the panel is already open (rail reopen and rail
 * reveal-a-background-tab share this one entry point in Reader.jsx).
 */
export function reopenPanel(api, id, userId) {
  if (api.getPanel(id)) return;
  const opts = { id, component: id, title: PANEL_TITLES[id] };

  // Prefer the dock the panel was last seen in: tabbed with a still-open
  // former tab mate, else the grid edge it occupied; otherwise fall through
  // to the default position rules below.
  const last = loadLastDock(userId)[id];
  if (last) {
    const mate = last.tabmates.map((pid) => api.getPanel(pid)).find(Boolean);
    if (mate) {
      opts.position = { direction: 'within', referencePanel: mate.id };
    } else if (last.side && api.panels.length > 0) {
      opts.position = { direction: SIDE_TO_DIRECTION[last.side] };
      if (last.side === 'bottom' || last.side === 'top') opts.initialHeight = 260;
      else opts.initialWidth = 420;
    }
    if (opts.position) {
      api.addPanel(opts);
      api.getPanel(id)?.api.setActive();
      return;
    }
  }

  if (id === PANEL_IDS.BIBLE) {
    const anchor = api.getPanel(PANEL_IDS.NOTES) || api.getPanel(PANEL_IDS.HIGHLIGHTS) || api.getPanel(PANEL_IDS.MESSAGING);
    if (anchor) opts.position = { direction: 'left', referencePanel: anchor.id };
  } else if (id === PANEL_IDS.NOTES || id === PANEL_IDS.HIGHLIGHTS || id === PANEL_IDS.MESSAGING) {
    const tabMate = [PANEL_IDS.NOTES, PANEL_IDS.HIGHLIGHTS, PANEL_IDS.MESSAGING]
      .filter((pid) => pid !== id)
      .map((pid) => api.getPanel(pid))
      .find(Boolean);
    if (tabMate) {
      opts.position = { direction: 'within', referencePanel: tabMate.id };
    } else {
      const bible = api.getPanel(PANEL_IDS.BIBLE);
      if (bible) opts.position = { direction: 'right', referencePanel: bible.id };
      if (id === PANEL_IDS.NOTES) opts.initialWidth = 420;
    }
  } else if (id === PANEL_IDS.AGENT_CHAT) {
    const bible = api.getPanel(PANEL_IDS.BIBLE);
    if (bible) {
      opts.position = { direction: 'below', referencePanel: bible.id };
      opts.initialHeight = 260;
    }
  }

  api.addPanel(opts);
  api.getPanel(id)?.api.setActive();
}
