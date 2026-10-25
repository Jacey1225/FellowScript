// AnnouncementPollsTests.swift — task 20261024-announcement-polls (iOS client logic).
// Model decoding, request JSON, form validation, apply-to-draft rules, and source pins.

import XCTest
@testable import FellowScript

final class AnnouncementPollsTests: XCTestCase {

    private func announcement(poll: FSAnnouncementPoll? = nil) -> FSGroupAnnouncement {
        FSGroupAnnouncement(id: "a1", group_id: "g1", creator_id: "u1", creator_username: "x", title: "t", description: "d",
                            banner_url: nil, publish_at: "2026-10-24T00:00:00+00:00", created_at: "2026-10-24T00:00:00+00:00",
                            updated_at: "2026-10-24T00:00:00+00:00", published: true, can_edit: true, poll: poll)
    }

    func test_decodes_serverPoll_andOldPayloadWithoutPoll() throws {
        let json = """
        {"id":"a1","group_id":"g1","creator_id":"u1","creator_username":"x","title":"t","description":"d","banner_url":null,
         "publish_at":"2026-10-24T00:00:00+00:00","created_at":"2026-10-24T00:00:00+00:00","updated_at":"2026-10-24T00:00:00+00:00",
         "published":true,"can_edit":false,
         "poll":{"question":"Q?","multiple":true,"closes_at":null,"closed":false,"total_voters":3,
                 "options":[{"id":"o1","label":"A","votes":2,"percent":67},{"id":"o2","label":"B","votes":1,"percent":33}],"my_votes":["o1"]}}
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(FSGroupAnnouncement.self, from: json)
        XCTAssertEqual(a.poll?.question, "Q?")
        XCTAssertEqual(a.poll?.options.map(\.percent), [67, 33])
        XCTAssertEqual(a.poll?.my_votes, ["o1"])
        XCTAssertTrue(a.poll?.multiple == true)
        let old = String(data: json, encoding: .utf8)!.replacingOccurrences(of: "\"poll\":{", with: "\"zzz\":{").data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(FSGroupAnnouncement.self, from: old).poll, "payloads without a poll still decode")
    }

    func test_draftJSON_poll_setClearUnchanged() {
        var d = FSAnnouncementDraft(title: "t", description: "d")
        XCTAssertNil(d.jsonObject["poll"], "unchanged omits the key")
        d.poll = .clear
        XCTAssertTrue(d.jsonObject["poll"] is NSNull)
        d.poll = .set(FSPollDraft(question: "Q?", options: ["A", "B"], multiple: true, closesAt: nil))
        let p = d.jsonObject["poll"] as? [String: Any]
        XCTAssertEqual(p?["question"] as? String, "Q?")
        XCTAssertEqual(p?["options"] as? [String], ["A", "B"])
        XCTAssertEqual(p?["multiple"] as? Bool, true)
        XCTAssertTrue(p?["closes_at"] is NSNull)
        d.poll = .set(FSPollDraft(question: "Q", options: ["A", "B"], closesAt: Date(timeIntervalSince1970: 4_000_000_000)))
        XCTAssertTrue(((d.jsonObject["poll"] as? [String: Any])?["closes_at"] as? String)?.hasSuffix("+00:00") == true)
    }

    func test_validation_catchesObviousMistakes() {
        var e = AnnouncementExtrasDraft(from: nil)
        XCTAssertNil(e.pollError(), "poll off = no error")
        e.pollOn = true
        XCTAssertNotNil(e.pollError(), "needs a question")
        e.pollQuestion = "Which night?"
        XCTAssertEqual(e.pollError(), "A poll needs at least 2 options.")
        e.pollOptions = ["Tue", " tue "]
        XCTAssertEqual(e.pollError(), "Each option has to be different.")
        e.pollOptions = ["Tue", "Wed"]
        XCTAssertNil(e.pollError())
        e.pollHasCloseTime = true; e.pollCloseTime = Date().addingTimeInterval(-60)
        XCTAssertEqual(e.pollError(), "Pick a close time in the future.")
        e.pollCloseTime = Date().addingTimeInterval(400 * 86_400)
        XCTAssertNotNil(e.pollError())
        e.pollCloseTime = Date().addingTimeInterval(3600)
        XCTAssertNil(e.pollError())
        XCTAssertEqual(e.blockingError(links: false, payments: false), nil)
        e.pollQuestion = ""
        XCTAssertNotNil(e.blockingError(links: false, payments: false), "the form's blocking error includes the poll")
    }

    func test_apply_sendsOnlyChanges_andClearsWhenTurnedOff() {
        // New announcement, poll added.
        var e = AnnouncementExtrasDraft(from: nil)
        e.pollOn = true; e.pollQuestion = " Pick  one "; e.pollOptions = ["A", "", "B"]; e.pollMultiple = true
        var d = FSAnnouncementDraft(title: "t", description: "d")
        e.apply(to: &d, original: nil, links: false, gallery: false, payments: false, rsvp: false, polls: true)
        guard case .set(let sent) = d.poll else { return XCTFail("poll should be set") }
        XCTAssertEqual(sent.question, "Pick one")
        XCTAssertEqual(sent.options, ["A", "B"])
        XCTAssertTrue(sent.multiple)
        // Flag off: nothing sent.
        var d2 = FSAnnouncementDraft(title: "t", description: "d")
        e.apply(to: &d2, original: nil, links: false, gallery: false, payments: false, rsvp: false, polls: false)
        XCTAssertEqual(d2.poll, .unchanged)
        // Editing an announcement with a poll: unchanged poll sends nothing; turning it off clears.
        let existing = FSAnnouncementPoll(question: "Q", multiple: false, closes_at: nil, closed: false, total_voters: 0,
                                          options: [FSPollOption(id: "1", label: "A", votes: 0, percent: 0),
                                                    FSPollOption(id: "2", label: "B", votes: 0, percent: 0)], my_votes: [])
        let item = announcement(poll: existing)
        var same = AnnouncementExtrasDraft(from: item)
        var d3 = FSAnnouncementDraft(title: "t", description: "d")
        same.apply(to: &d3, original: item, links: false, gallery: false, payments: false, rsvp: false, polls: true)
        XCTAssertEqual(d3.poll, .unchanged)
        same.pollOn = false
        var d4 = FSAnnouncementDraft(title: "t", description: "d")
        same.apply(to: &d4, original: item, links: false, gallery: false, payments: false, rsvp: false, polls: true)
        XCTAssertEqual(d4.poll, .clear)
    }

    func test_votedPoll_locksOptions() {
        let voted = FSAnnouncementPoll(question: "Q", multiple: false, closes_at: nil, closed: false, total_voters: 2,
                                       options: [FSPollOption(id: "1", label: "A", votes: 2, percent: 100),
                                                 FSPollOption(id: "2", label: "B", votes: 0, percent: 0)], my_votes: [])
        XCTAssertTrue(AnnouncementExtrasDraft(from: announcement(poll: voted)).pollLocked)
        XCTAssertFalse(AnnouncementExtrasDraft(from: nil).pollLocked)
    }

    func test_pollActions_bindOneAnnouncement_andClosingNeedsEditRights() async throws {
        final class Fake: AnnouncementPollsService {
            var calls: [String] = []
            func pollVote(userId: String, groupId: String, announcementId: String, optionIds: [String]) async throws -> FSGroupAnnouncement {
                calls.append("vote:\(announcementId):\(optionIds.joined(separator: ","))"); return Self.item(announcementId)
            }
            func pollRetract(userId: String, groupId: String, announcementId: String) async throws -> FSGroupAnnouncement {
                calls.append("retract:\(announcementId)"); return Self.item(announcementId)
            }
            func pollClose(userId: String, groupId: String, announcementId: String) async throws -> FSGroupAnnouncement {
                calls.append("close:\(announcementId)"); return Self.item(announcementId)
            }
            static func item(_ id: String) -> FSGroupAnnouncement {
                FSGroupAnnouncement(id: id, group_id: "g", creator_id: nil, creator_username: nil, title: "t", description: "d",
                                    banner_url: nil, publish_at: "", created_at: "", updated_at: "", published: true, can_edit: false)
            }
        }
        let fake = Fake()
        var seen: [String] = []
        var editor = announcement(); editor.can_edit = true
        var member = announcement(); member.can_edit = false
        let a = try XCTUnwrap(AnnouncementPollActions.make(service: fake, userId: "u", groupId: "g", item: editor) { seen.append($0.id) })
        _ = try await a.vote(["o1", "o2"]); _ = try await a.retract(); _ = try await XCTUnwrap(a.close)()
        XCTAssertEqual(fake.calls, ["vote:a1:o1,o2", "retract:a1", "close:a1"])
        XCTAssertEqual(seen, ["a1", "a1", "a1"], "owner is told so it can replace its cached copy")
        let m = try XCTUnwrap(AnnouncementPollActions.make(service: fake, userId: "u", groupId: "g", item: member) { _ in })
        XCTAssertNil(m.close, "members can't close")
        XCTAssertNil(AnnouncementPollActions.make(service: nil, userId: "u", groupId: "g", item: editor) { _ in })
    }

    // MARK: source pins

    private func src(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("FellowScript/\(rel)"), encoding: .utf8)
    }

    func test_pins_flagGated_anonymous_andWiredInEveryHost() throws {
        XCTAssertEqual(AnnouncementExtrasFlag.polls, "announcement_polls")
        let form = try src("Chat/GroupAnnouncementFormView.swift")
        XCTAssertTrue(form.contains("capabilities.isEnabled(AnnouncementExtrasFlag.polls)"))
        XCTAssertTrue(form.contains("polls: pollsOn"))
        XCTAssertTrue(try src("Chat/AnnouncementExtrasDetail.swift").contains("Votes are anonymous. Only counts are shown."))
        for host in ["Chat/GroupAnnouncementsView.swift", "Chat/GroupInfoPanelHost.swift", "Chat/GroupAnnouncementWidgetView.swift"] {
            XCTAssertTrue(try src(host).contains("pollActions:"), "\(host) passes poll actions to the detail view")
        }
        let svc = try src("Services/NetworkService+AnnouncementPolls.swift")
        XCTAssertFalse(svc.contains("user_id"), "the voter is the session user, never a body field")
        XCTAssertTrue(svc.contains("/poll"))
    }

    func test_previewSeam_isDebugOnly() throws {
        let preview = try src("Chat/AnnouncementPollsPreview.swift")
        XCTAssertTrue(preview.hasPrefix("// AnnouncementPollsPreview.swift") && preview.contains("#if DEBUG"))
        let app = try src("FellowScriptApp.swift")
        XCTAssertTrue(app.contains("#if DEBUG\n        RootOrPollsPreview()\n        #else\n        ContentView()"))
    }
}
