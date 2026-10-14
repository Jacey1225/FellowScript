// Codable response types from POST /devotions/join-call.
// No AmazonChimeSDK dependency — safe to import anywhere.

struct ChimeMediaPlacement: Codable {
    let AudioHostUrl:       String
    let AudioFallbackUrl:   String
    let SignalingUrl:       String
    let TurnControlUrl:     String
    let EventIngestionUrl:  String?
}

struct ChimeMeetingInfo: Codable {
    let MeetingId:         String
    let ExternalMeetingId: String?
    let MediaRegion:       String
    let MediaPlacement:    ChimeMediaPlacement
}

struct ChimeAttendeeInfo: Codable {
    let AttendeeId:     String
    let ExternalUserId: String
    let JoinToken:      String
}

struct ChimeJoinResponse: Codable {
    let Meeting:  ChimeMeetingInfo
    let Attendee: ChimeAttendeeInfo
    // Task 20261013-session-call-live-transcript-summary: present on the main
    // join-call response only (nil on a discussion room's meeting, and on an
    // older server). nil/false means no consent banner and no relay.
    var transcription_active:      Bool? = nil   // banner signal, true for late joiners too
    var transcript_relay:          Bool? = nil   // this caller is the designated relay right now
    var transcript_poll_seconds:   Int?  = nil   // relay-status poll interval
}
