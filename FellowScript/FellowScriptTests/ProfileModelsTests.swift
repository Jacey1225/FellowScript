// ProfileModelsTests.swift (task 20261030-user-profiles, testing step 8)
// FSProfile wire decode (bio absent vs null vs string; unknown relationship
// throws) and the memory-only ProfileCache.

import XCTest
@testable import FellowScript

@MainActor
final class ProfileModelsTests: XCTestCase {

    private func decode(_ json: String) throws -> FSProfile {
        try JSONDecoder().decode(FSProfile.self, from: Data(json.utf8))
    }

    func test_decode_bioKeyAbsent_isHiddenNotEmpty() throws {
        let p = try decode(#"{"user_id":"u1","username":"ann","profile_photo_url":null,"relationship":{"state":"none"},"editable":false}"#)
        XCTAssertFalse(p.bioVisible, "a missing bio key means hidden from this viewer (stranger tier)")
        XCTAssertNil(p.bio)
        XCTAssertEqual(p.relationship, .none)
        XCTAssertFalse(p.editable)
    }

    func test_decode_bioKeyPresentNull_isVisibleButEmpty() throws {
        let p = try decode(#"{"user_id":"u1","username":"ann","relationship":{"state":"friends"},"editable":false,"bio":null}"#)
        XCTAssertTrue(p.bioVisible)
        XCTAssertNil(p.bio)
    }

    func test_decode_bioString() throws {
        let p = try decode(#"{"user_id":"u1","username":"ann","relationship":{"state":"self"},"editable":true,"bio":"Walking with Jesus"}"#)
        XCTAssertTrue(p.bioVisible)
        XCTAssertEqual(p.bio, "Walking with Jesus")
        XCTAssertEqual(p.relationship, .selfUser)
        XCTAssertTrue(p.editable)
    }

    func test_decode_allRelationshipStates() throws {
        let pairs: [(String, FSProfileRelationship)] = [
            ("self", .selfUser), ("friends", .friends), ("request_sent", .requestSent),
            ("request_received", .requestReceived), ("none", .none)]
        for (raw, expected) in pairs {
            let p = try decode(#"{"user_id":"u","username":"n","relationship":{"state":"\#(raw)"},"editable":false}"#)
            XCTAssertEqual(p.relationship, expected, raw)
        }
    }

    func test_decode_unknownRelationshipState_throwsInsteadOfGuessing() {
        XCTAssertThrowsError(try decode(#"{"user_id":"u","username":"n","relationship":{"state":"blocked"},"editable":false}"#))
    }

    func test_decode_missingRequiredFields_throws() {
        XCTAssertThrowsError(try decode(#"{"user_id":"u","relationship":{"state":"none"},"editable":false}"#), "no username")
        XCTAssertThrowsError(try decode(#"{"user_id":"u","username":"n","relationship":{"state":"none"}}"#), "no editable flag")
        XCTAssertThrowsError(try decode(#"{"user_id":"u","username":"n","editable":false}"#), "no relationship")
    }

    func test_decode_ignoresUnexpectedEmailKey_neverSurfacesIt() throws {
        let p = try decode(#"{"user_id":"u","username":"n","email":"leak@example.com","relationship":{"state":"none"},"editable":false}"#)
        XCTAssertEqual(p.username, "n")
        XCTAssertFalse(String(describing: p).contains("leak@example.com"))
    }

    // MARK: ProfileCache

    func test_cache_isKeyedByViewerAndTarget() {
        let cache = ProfileCache()
        let p = FSProfile(user_id: "t", username: "ann", relationship: .friends, editable: false, bio: "private", bioVisible: true)
        cache.store(p, viewer: "v1")
        XCTAssertEqual(cache.profile(viewer: "v1", target: "t"), p)
        XCTAssertNil(cache.profile(viewer: "v2", target: "t"), "another account must never read this viewer's cached bio")
        XCTAssertNil(cache.profile(viewer: "v1", target: "other"))
    }

    func test_cache_evictAndClear() {
        let cache = ProfileCache()
        let a = FSProfile(user_id: "a", username: "a", relationship: .none, editable: false, bioVisible: false)
        let b = FSProfile(user_id: "b", username: "b", relationship: .none, editable: false, bioVisible: false)
        cache.store(a, viewer: "v"); cache.store(b, viewer: "v")
        cache.evict(viewer: "v", target: "a")
        XCTAssertNil(cache.profile(viewer: "v", target: "a"))
        XCTAssertNotNil(cache.profile(viewer: "v", target: "b"))
        cache.clear()
        XCTAssertNil(cache.profile(viewer: "v", target: "b"), "sign-out clears everything")
    }
}
