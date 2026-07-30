// One context per dockable Reader panel. Kept separate (rather than one merged
// context) so e.g. an incoming chat message never re-renders the Bible panel,
// a chapter navigation never re-renders Messaging, etc. Reader.jsx builds one
// memoized value per domain and provides all five around its entire render
// output — dockview only ever reads these through React context, which is
// unaffected by dockview's own DOM reparenting during a drag (panel content
// renders through a portal; the component instance and its state survive).
import { createContext, useContext } from 'react';

export const BibleReaderPanelContext = createContext(null);
export const NotesPanelContext       = createContext(null);
export const HighlightsPanelContext  = createContext(null);
export const MessagingPanelContext   = createContext(null);
export const AgentChatPanelContext   = createContext(null);

export function useBibleReaderPanel() { return useContext(BibleReaderPanelContext); }
export function useNotesPanel()       { return useContext(NotesPanelContext); }
export function useHighlightsPanel()  { return useContext(HighlightsPanelContext); }
export function useMessagingPanel()   { return useContext(MessagingPanelContext); }
export function useAgentChatPanel()   { return useContext(AgentChatPanelContext); }
