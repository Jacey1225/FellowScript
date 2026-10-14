import { createContext, useContext } from 'react';

// Task 20261011-web-session-screenshare-rooms. Carries the live-call extras
// (screen share + discussion rooms + who is in the current Chime meeting) from
// useSessions down to SessionCallScreen without threading more props through
// Reader -> ChatThread -> SessionsMenu -> SessionCard -> ActiveCard.
//
// Outside a provider (unit tests, isolated components) both are null: the call
// screen then shows neither feature, the fail-closed default. The server
// feature flags (screen_share_enabled, discussion_rooms) are checked
// separately via CapabilitiesContext.
//
// transcriptionActive (task 20261013-session-call-live-transcript-summary):
// true while the server is transcribing the main call; drives the consent banner.
export const CallFeaturesContext = createContext({ screenShare: null, rooms: null, meetingPresence: [], bindVideoTile: null, transcriptionActive: false });

export function useCallFeatures() {
  return useContext(CallFeaturesContext);
}
