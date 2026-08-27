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

export const LAYOUT_STORAGE_KEY = 'fs_reader_layout_v1';
export const LAYOUT_VERSION = 1;

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

export function loadSavedLayout(api) {
  try {
    const raw = localStorage.getItem(LAYOUT_STORAGE_KEY);
    if (!raw) return false;
    const parsed = JSON.parse(raw);
    if (!parsed || parsed.version !== LAYOUT_VERSION || !parsed.layout) return false;
    api.fromJSON(parsed.layout);
    return true;
  } catch {
    return false;
  }
}

export function saveLayout(api) {
  try {
    localStorage.setItem(LAYOUT_STORAGE_KEY, JSON.stringify({ version: LAYOUT_VERSION, layout: api.toJSON() }));
  } catch {}
}

export function resetLayout(api) {
  api.clear();
  buildDefaultLayout(api);
  saveLayout(api);
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
export function reopenPanel(api, id) {
  if (api.getPanel(id)) return;
  const opts = { id, component: id, title: PANEL_TITLES[id] };

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
