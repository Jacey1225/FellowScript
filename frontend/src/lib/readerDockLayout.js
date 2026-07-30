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
