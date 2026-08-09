// ChimeModelsDecodeTests.swift — regression coverage for task
// 20260808-ios-backend-integration-audit, backend step 17 finding / frontend
// step 18 fix.
//
// Incident #2's exact shape-mismatch pattern (client/server field-name
// mismatch causing a silent nil), found on the devotion/Chime surface:
// ChimeMediaPlacement previously declared `let IngestionUrl: String?`, but
// AWS's chime-sdk-meetings CreateMeeting response actually names this field
// `EventIngestionUrl`. api/routes/devotion.py's join_call passes the raw
// boto3 response straight through unmodified, so the backend was never the
// problem — the Swift struct's property name just never matched the real
// JSON key. Because the property was Optional, Swift's synthesized
// Decodable used decodeIfPresent and silently decoded to nil on every call
// instead of crashing or dropping the whole response — permanently losing
// that one value and silently degrading Chime's own meeting-quality
// telemetry (ChimeCallView line ~134 feeds it into AmazonChimeSDK's
// `eventIngestionUrl:` parameter).
//
// Fixed by renaming the property to `EventIngestionUrl` (matches AWS's real
// key exactly, no CodingKeys needed).
//
// This test decodes a JSON payload shaped exactly like AWS's real
// CreateMeeting response (verified against AWS's chime-sdk-meetings API
// docs — the key is `EventIngestionUrl`) and proves the value round-trips
// instead of silently becoming nil.

import XCTest
@testable import FellowScript

final class ChimeModelsDecodeTests: XCTestCase {

    /// The load-bearing assertion: a real AWS response's `EventIngestionUrl`
    /// key must decode into a non-nil value. Before the fix (`IngestionUrl`),
    /// this would have decoded to nil with zero error — the whole point of
    /// this regression pattern is that it fails silently, so an explicit
    /// non-nil assertion is required to catch it.
    func test_chimeMediaPlacement_decodesRealAWSFieldName_eventIngestionUrl() throws {
        let json = """
        {
            "AudioHostUrl": "audiohost.example.com",
            "AudioFallbackUrl": "audiofallback.example.com",
            "SignalingUrl": "signaling.example.com",
            "TurnControlUrl": "turncontrol.example.com",
            "EventIngestionUrl": "eventingestion.example.com"
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChimeMediaPlacement.self, from: data)

        XCTAssertEqual(decoded.EventIngestionUrl, "eventingestion.example.com",
                        "EventIngestionUrl must decode from AWS's real JSON key, not silently become nil")
        XCTAssertEqual(decoded.AudioHostUrl, "audiohost.example.com")
        XCTAssertEqual(decoded.AudioFallbackUrl, "audiofallback.example.com")
        XCTAssertEqual(decoded.SignalingUrl, "signaling.example.com")
        XCTAssertEqual(decoded.TurnControlUrl, "turncontrol.example.com")
    }

    /// Regression guard: the field is genuinely Optional (some CreateMeeting
    /// responses may omit it) — a response missing the key entirely must
    /// still decode successfully with a nil value, not throw.
    func test_chimeMediaPlacement_decodesSuccessfully_whenEventIngestionUrlOmitted() throws {
        let json = """
        {
            "AudioHostUrl": "audiohost.example.com",
            "AudioFallbackUrl": "audiofallback.example.com",
            "SignalingUrl": "signaling.example.com",
            "TurnControlUrl": "turncontrol.example.com"
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChimeMediaPlacement.self, from: data)

        XCTAssertNil(decoded.EventIngestionUrl)
    }

    /// Full end-to-end shape check: the whole ChimeJoinResponse (as returned
    /// by POST /devotions/join-call) decodes correctly, including the nested
    /// EventIngestionUrl.
    func test_chimeJoinResponse_decodesFullResponseShape() throws {
        let json = """
        {
            "Meeting": {
                "MeetingId": "meeting-123",
                "ExternalMeetingId": "ext-meeting-123",
                "MediaRegion": "us-east-1",
                "MediaPlacement": {
                    "AudioHostUrl": "audiohost.example.com",
                    "AudioFallbackUrl": "audiofallback.example.com",
                    "SignalingUrl": "signaling.example.com",
                    "TurnControlUrl": "turncontrol.example.com",
                    "EventIngestionUrl": "eventingestion.example.com"
                }
            },
            "Attendee": {
                "AttendeeId": "attendee-456",
                "ExternalUserId": "user-789",
                "JoinToken": "join-token-abc"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChimeJoinResponse.self, from: data)

        XCTAssertEqual(decoded.Meeting.MeetingId, "meeting-123")
        XCTAssertEqual(decoded.Meeting.MediaPlacement.EventIngestionUrl, "eventingestion.example.com")
        XCTAssertEqual(decoded.Attendee.JoinToken, "join-token-abc")
    }
}
