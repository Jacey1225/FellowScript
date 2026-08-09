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
}
