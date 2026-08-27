import React from 'react';
import { BookOutlined, FileTextOutlined, HighlightOutlined, MessageOutlined, RobotOutlined } from '@ant-design/icons';
import { PANEL_IDS, PANEL_TITLES } from '../../lib/readerDockLayout.js';

// Left dock rail (20260825-reader-dock-rail-polish, item 3) — fixed,
// always-visible vertical icon rail per dockable-glass-layout design-spec
// §3.4 (icon set, active=filled-gold / inactive-or-available=60%-opacity-
// outline states) and nav-search-revision §2.1 (rail geometry, full height
// below the header, fixed). Geometry/chrome live in reader-dock.css
// (.reader-dock-rail); this file only owns the icon roster + selection
// state -> click wiring.
//
// Scoped strictly to this app's five existing dockable panel types
// (PANEL_IDS) rather than the ground-truth spec's own icon list (which also
// shows separate Direct Messages/Group Chat/Schedule icons) — those aren't
// real panel types in this app's roster today, and building them is out of
// scope for this task (see intake-spec.md's "Item 3 panel-type mapping" open
// question, resolved in favor of the bounded/recommended reading). Order
// mirrors PANEL_IDS's own declaration order in readerDockLayout.js.
const RAIL_ITEMS = [
  { id: PANEL_IDS.BIBLE,      Icon: BookOutlined },
  { id: PANEL_IDS.NOTES,      Icon: FileTextOutlined },
  { id: PANEL_IDS.HIGHLIGHTS, Icon: HighlightOutlined },
  { id: PANEL_IDS.MESSAGING,  Icon: MessageOutlined },
  { id: PANEL_IDS.AGENT_CHAT, Icon: RobotOutlined },
];

/**
 * @param {Set<string>} openPanelIds - panel ids currently present in the live dockview layout
 * @param {string|null} activePanelId - the id of the currently active/visible panel, if any
 * @param {(id: string) => void} onSelect - called with a panel id on click; Reader.jsx decides
 *   whether that means "activate" (already open, e.g. a background tab) or "reopen" (closed).
 */
export default function ReaderDockRail({ openPanelIds, activePanelId, onSelect }) {
  return (
    <div className="reader-dock-rail dockview-theme-abyss" role="toolbar" aria-label="Reader panels" aria-orientation="vertical">
      {RAIL_ITEMS.map(({ id, Icon }) => {
        const isOpen = openPanelIds.has(id);
        const isActive = activePanelId === id;
        const label = PANEL_TITLES[id];
        return (
          <button
            key={id}
            type="button"
            className={`reader-dock-rail-icon${isActive ? ' active' : ''}`}
            onClick={() => onSelect(id)}
            title={isOpen ? label : `Open ${label}`}
            aria-label={label}
            aria-pressed={isActive}
            data-panel-id={id}
            data-panel-open={isOpen}
          >
            <Icon />
          </button>
        );
      })}
    </div>
  );
}
