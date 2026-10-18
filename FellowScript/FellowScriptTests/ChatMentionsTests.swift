// ChatMentionsTests.swift -- task 20261017-chat-mentions, iOS.
// Pure-logic tests only: UTF-16 offsets (emoji, accents), range validation,
// trigger detection, filtering, edit maintenance, run splitting for rendering,
// and Codable decode of payloads with and without `mentions`. No network, no
// URLProtocol, no run-loop pumping, no NSAttributedString HTML import.

import XCTest
@testable import FellowScript

// MARK: - Logic

final class ChatMentionsLogicTests: XCTestCase {

    private func cand(_ id: String, _ name: String) -> FSMentionCandidate {
        FSMentionCandidate(userId: id, username: name)
    }

    // MARK: offsets

    func test_insert_recordsUTF16Offsets_afterEmoji() {
        // "hi " + a family emoji (1 grapheme, 11 UTF-16 units) + " @Ma"
        var d = MentionDraft()
        let text = "hi 👨‍👩‍👧 @Ma"
        let trig = MentionDraft.trigger(in: text, caret: text.utf16.count)
        XCTAssertEqual(trig?.query, "Ma")
        let out = d.insert(cand("u1", "Matthew"), trigger: trig!, into: text)
        XCTAssertEqual(out, "hi 👨‍👩‍👧 @Matthew ")
        let m = d.mentions[0]
        XCTAssertEqual(m.start, "hi 👨‍👩‍👧 ".utf16.count)
        XCTAssertNotEqual(m.start, "hi 👨‍👩‍👧 ".count, "grapheme count is not the unit")
        XCTAssertEqual(m.length, "@Matthew".utf16.count)
        XCTAssertEqual(MentionText16.slice(out!, start: m.start, length: m.length), "@Matthew")
    }

    func test_insert_accentedAndEmojiUsername_lengthIsUTF16() {
        var d = MentionDraft()
        let text = "@Jo"
        let out = d.insert(cand("u1", "José🙂"), trigger: MentionDraft.trigger(in: text, caret: 3)!, into: text)
        XCTAssertEqual(d.mentions[0].length, 1 + "José🙂".utf16.count)
        XCTAssertEqual(d.mentions[0].length, 7, "@ + J o s é + 2 units for the emoji")
        XCTAssertEqual(out, "@José🙂 ")
        XCTAssertEqual(d.verified(for: out!).count, 1)
    }

    func test_insert_noSecondSpaceWhenNextCharIsSpace() {
        var d = MentionDraft()
        let text = "@Ma tail"
        let out = d.insert(cand("u1", "Mat"), trigger: MentionDraft.Trigger(at: 0, query: "Ma"), into: text)
        XCTAssertEqual(out, "@Mat tail")
        XCTAssertEqual(d.mentions[0].length, 4)
    }

    func test_insert_rejectsDuplicateAndCap() {
        var d = MentionDraft()
        var text = "@a"
        text = d.insert(cand("u1", "alice"), trigger: .init(at: 0, query: "a"), into: text)!
        text += "@a"
        let t2 = MentionDraft.trigger(in: text, caret: text.utf16.count)!
        XCTAssertNil(d.insert(cand("U1", "alice"), trigger: t2, into: text), "one mention per person")
        d.mentions = (0..<10).map { FSMention(userId: "u\($0)", start: $0 * 3, length: 2, username: "x") }
        XCTAssertNil(d.insert(cand("z", "zed"), trigger: t2, into: text), "cap of 10")
        XCTAssertTrue(d.candidates(from: [cand("z", "zed")], query: "").isEmpty)
    }

    func test_outgoing_shiftsForLeadingWhitespaceTrim() {
        var d = MentionDraft()
        let raw = "  \n@Bob hello"
        d.mentions = [FSMention(userId: "u", start: 3, length: 4, username: "Bob")]
        let out = d.outgoing(rawText: raw)
        XCTAssertEqual(out.text, "@Bob hello")
        XCTAssertEqual(out.mentions.first?.start, 0)
        XCTAssertEqual(out.mentions.first?.length, 4)
    }

    func test_outgoing_dropsMentionWhoseTextNoLongerMatches() {
        var d = MentionDraft()
        d.mentions = [FSMention(userId: "u", start: 0, length: 4, username: "Bob")]
        XCTAssertTrue(d.outgoing(rawText: "@Bab hi").mentions.isEmpty)
        XCTAssertEqual(d.outgoing(rawText: "@Bob hi").mentions.count, 1)
    }

    func test_outgoingJSON_hasExactlyThreeKeys() {
        let json = FSMention(userId: "u", start: 1, length: 2, username: "x").outgoingJSON
        XCTAssertEqual(Set(json.keys), ["user_id", "start", "length"])
    }

    // MARK: validation

    func test_validRanges_dropsInvalid() {
        let text = "hey @Ann and @Bo!"
        let ok = FSMention(userId: "a", start: 4, length: 4, username: "Ann")
        let ok2 = FSMention(userId: "b", start: 13, length: 3, username: "Bo")
        XCTAssertEqual(MentionRender.validRanges([ok, ok2], in: text), [ok, ok2])
        XCTAssertTrue(MentionRender.validRanges([FSMention(userId: "a", start: 4, length: 99)], in: text).isEmpty, "past the end")
        XCTAssertTrue(MentionRender.validRanges([FSMention(userId: "a", start: -1, length: 4)], in: text).isEmpty, "negative start")
        XCTAssertTrue(MentionRender.validRanges([FSMention(userId: "a", start: 4, length: 1)], in: text).isEmpty, "too short")
        XCTAssertTrue(MentionRender.validRanges([FSMention(userId: "a", start: 5, length: 3)], in: text).isEmpty, "does not start at @")
        XCTAssertEqual(MentionRender.validRanges([ok, FSMention(userId: "c", start: 6, length: 4)], in: text), [ok], "overlap skipped")
        XCTAssertEqual(MentionRender.validRanges([ok2, ok], in: text), [ok2], "unsorted: later one skipped")
        XCTAssertTrue(MentionRender.validRanges(nil, in: text).isEmpty)
        XCTAssertTrue(MentionRender.validRanges([ok], in: "").isEmpty)
    }

    func test_validRanges_rejectsSplitSurrogatePair() {
        let text = "@😀x"   // @ + 2 units + x
        XCTAssertTrue(MentionRender.validRanges([FSMention(userId: "a", start: 0, length: 2)], in: text).isEmpty)
        XCTAssertEqual(MentionRender.validRanges([FSMention(userId: "a", start: 0, length: 3)], in: text).count, 1)
    }

    // MARK: trigger

    func test_trigger_startAfterWhitespaceOnly() {
        XCTAssertEqual(MentionDraft.trigger(in: "@", caret: 1), .init(at: 0, query: ""))
        XCTAssertEqual(MentionDraft.trigger(in: "hi @bo", caret: 6), .init(at: 3, query: "bo"))
        XCTAssertEqual(MentionDraft.trigger(in: "hi\n@bo", caret: 6)?.at, 3)
        XCTAssertNil(MentionDraft.trigger(in: "a@b", caret: 3), "mid-word / email")
        XCTAssertNil(MentionDraft.trigger(in: "hi @bo ", caret: 7), "whitespace after the query closes it")
        XCTAssertNil(MentionDraft.trigger(in: "hi @a@b", caret: 7))
        XCTAssertNil(MentionDraft.trigger(in: "hello", caret: 5))
        XCTAssertNil(MentionDraft.trigger(in: "", caret: 0))
        XCTAssertNil(MentionDraft.trigger(in: "@x", caret: 9), "caret out of range")
    }

    func test_trigger_afterEmojiUsesUTF16Offset() {
        let text = "😀 @a"
        let t = MentionDraft.trigger(in: text, caret: text.utf16.count)
        XCTAssertEqual(t?.at, 3)
        XCTAssertEqual(t?.query, "a")
    }

    // MARK: filtering

    func test_filter_prefixThenWordStartThenContains() {
        let pool = [cand("1", "Marcus"), cand("2", "Sam Mark"), cand("3", "Tamara"), cand("4", "Bob")]
        XCTAssertEqual(MentionDraft.filter(pool, query: "mar").map(\.userId), ["1", "2", "3"])
        XCTAssertEqual(MentionDraft.filter(pool, query: "MAR").map(\.userId), ["1", "2", "3"], "case-insensitive")
        XCTAssertEqual(MentionDraft.filter(pool, query: "").map(\.userId), ["1", "2", "3", "4"])
        XCTAssertTrue(MentionDraft.filter(pool, query: "zzz").isEmpty)
    }

    func test_candidates_excludeAlreadyMentioned() {
        var d = MentionDraft()
        d.mentions = [FSMention(userId: "1", start: 0, length: 4, username: "Marc")]
        let pool = [cand("1", "Marc"), cand("2", "Mary")]
        XCTAssertEqual(d.candidates(from: pool, query: "ma").map(\.userId), ["2"])
    }

    // MARK: edits

    private func draftWithBob() -> (MentionDraft, String) {
        var d = MentionDraft()
        let text = "hi @Bob there"
        d.mentions = [FSMention(userId: "u", start: 3, length: 4, username: "Bob")]
        return (d, text)
    }

    func test_edit_typingBeforeShiftsMention() {
        var (d, text) = draftWithBob()
        let new = "oh " + text
        XCTAssertEqual(d.applyEdit(oldText: text, newText: new), new)
        XCTAssertEqual(d.mentions.first?.start, 6)
    }

    func test_edit_typingAfterKeepsMention() {
        var (d, text) = draftWithBob()
        let new = text + "!"
        XCTAssertEqual(d.applyEdit(oldText: text, newText: new), new)
        XCTAssertEqual(d.mentions.first?.start, 3)
    }

    func test_edit_backspaceInsideRemovesWholeMention() {
        var (d, text) = draftWithBob()
        // delete the "b" of "@Bob" (index 5)
        let new = "hi @Bo there"
        XCTAssertEqual(d.applyEdit(oldText: text, newText: new), "hi  there")
        XCTAssertTrue(d.mentions.isEmpty)
    }

    func test_edit_deletingTheSpaceAfterMentionRemovesWholeMention() {
        var d = MentionDraft()
        let old = "hi @Bob "
        d.mentions = [FSMention(userId: "u", start: 3, length: 4, username: "Bob")]
        XCTAssertEqual(d.applyEdit(oldText: old, newText: "hi @Bob"), "hi ")
        XCTAssertTrue(d.mentions.isEmpty)
    }

    func test_edit_removalShiftsLaterMentions() {
        var d = MentionDraft()
        let old = "@Al and @Bo ok"
        d.mentions = [FSMention(userId: "a", start: 0, length: 3, username: "Al"),
                      FSMention(userId: "b", start: 8, length: 3, username: "Bo")]
        // delete "l" in @Al
        let new = "@A and @Bo ok"
        let out = d.applyEdit(oldText: old, newText: new)
        XCTAssertEqual(out, " and @Bo ok")
        XCTAssertEqual(d.mentions.count, 1)
        XCTAssertEqual(d.mentions[0].userId, "b")
        XCTAssertEqual(d.mentions[0].start, 5)
        XCTAssertEqual(MentionText16.slice(out, start: 5, length: 3), "@Bo")
    }

    func test_edit_typingInsideMentionDropsRecordKeepsText() {
        var (d, text) = draftWithBob()
        let new = "hi @Bxob there"
        XCTAssertEqual(d.applyEdit(oldText: text, newText: new), new)
        XCTAssertTrue(d.mentions.isEmpty)
    }

    func test_edit_clearingTextClearsMentions() {
        var (d, text) = draftWithBob()
        XCTAssertEqual(d.applyEdit(oldText: text, newText: ""), "")
        XCTAssertTrue(d.mentions.isEmpty)
    }

    func test_edit_withEmojiBeforeMention() {
        var d = MentionDraft()
        let old = "😀 @Bo"
        d.mentions = [FSMention(userId: "u", start: 3, length: 3, username: "Bo")]
        let new = "😀😀 @Bo"
        XCTAssertEqual(d.applyEdit(oldText: old, newText: new), new)
        XCTAssertEqual(d.mentions.first?.start, 5)
        XCTAssertEqual(d.verified(for: new).count, 1)
    }

    // MARK: rendering runs

    func test_runs_splitPlainAndMention() {
        let text = "hey @Ann, hi"
        let runs = MentionRender.runs(text: text, mentions: [FSMention(userId: "a", start: 4, length: 4, username: "Ann")])
        XCTAssertEqual(runs, [.init(text: "hey ", isMention: false),
                              .init(text: "@Ann", isMention: true),
                              .init(text: ", hi", isMention: false)])
    }

    func test_runs_usesCurrentUsernameWithoutShiftingLaterRuns() {
        // stored text says @Ann (4 units); the user has since been renamed "Annabelle".
        let text = "@Ann and @Bo"
        let runs = MentionRender.runs(text: text, mentions: [
            FSMention(userId: "a", start: 0, length: 4, username: "Annabelle"),
            FSMention(userId: "b", start: 9, length: 3, username: "Bo")])
        XCTAssertEqual(runs.map(\.text), ["@Annabelle", " and ", "@Bo"])
        XCTAssertEqual(runs.map(\.isMention), [true, false, true])
    }

    func test_runs_missingUsernameFallsBackToStoredSlice() {
        let runs = MentionRender.runs(text: "x @Gone y", mentions: [FSMention(userId: "g", start: 2, length: 5)])
        XCTAssertEqual(runs.map(\.text), ["x ", "@Gone", " y"])
    }

    func test_runs_emojiBeforeMention() {
        let text = "🎉🎉 @Zoë!"
        let start = "🎉🎉 ".utf16.count
        let runs = MentionRender.runs(text: text, mentions: [FSMention(userId: "z", start: start, length: 4, username: "Zoë")])
        XCTAssertEqual(runs.map(\.text), ["🎉🎉 ", "@Zoë", "!"])
    }

    func test_runs_invalidRangesRenderPlain() {
        let text = "hello world"
        let runs = MentionRender.runs(text: text, mentions: [FSMention(userId: "a", start: 50, length: 4, username: "x")])
        XCTAssertEqual(runs, [.init(text: text, isMention: false)])
        XCTAssertEqual(MentionRender.runs(text: text, mentions: nil), [.init(text: text, isMention: false)])
        XCTAssertTrue(MentionRender.runs(text: "", mentions: nil).isEmpty)
        XCTAssertFalse(MentionRender.hasMentions([FSMention(userId: "a", start: 50, length: 4)], in: text))
    }
}

// MARK: - Decode

final class ChatMentionsDecodeTests: XCTestCase {

    func test_rawMsg_withMentions_decodesAndIgnoresUnknownKeys() throws {
        let json = #"{"id":"m1","text":"hi @Bob","from_user":"al","timestamp":"t","mine":false,"brand_new_key":{"a":1},"mentions":[{"user_id":"u1","start":3,"length":4,"username":"Bob","future":true}]}"#
        let raw = try JSONDecoder().decode(RawMsg.self, from: Data(json.utf8))
        let msg = NetworkService.pagedMessage(raw)
        XCTAssertEqual(msg.mentions, [FSMention(userId: "u1", start: 3, length: 4, username: "Bob")])
    }

    func test_rawMsg_withoutMentions_isNil() throws {
        let json = #"{"id":"m1","text":"hi","from_user":"al","timestamp":"t","mine":false}"#
        let msg = NetworkService.pagedMessage(try JSONDecoder().decode(RawMsg.self, from: Data(json.utf8)))
        XCTAssertNil(msg.mentions)
        let nullJSON = #"{"id":"m1","text":"hi","timestamp":"t","mentions":null}"#
        XCTAssertNil(NetworkService.pagedMessage(try JSONDecoder().decode(RawMsg.self, from: Data(nullJSON.utf8))).mentions)
        let emptyJSON = #"{"id":"m1","text":"hi","timestamp":"t","mentions":[]}"#
        XCTAssertNil(NetworkService.pagedMessage(try JSONDecoder().decode(RawMsg.self, from: Data(emptyJSON.utf8))).mentions)
    }

    func test_rawMsg_malformedMentions_neverThrowOrDropTheMessage() throws {
        let notArray = #"{"id":"m1","text":"hi","timestamp":"t","mentions":"oops"}"#
        let a = try JSONDecoder().decode(RawMsg.self, from: Data(notArray.utf8))
        XCTAssertEqual(a.id, "m1")
        XCTAssertNil(NetworkService.pagedMessage(a).mentions)
        let mixed = #"{"id":"m2","text":"@A @B","timestamp":"t","mentions":[{"user_id":"a"},{"user_id":"b","start":3,"length":2},7]}"#
        let b = NetworkService.pagedMessage(try JSONDecoder().decode(RawMsg.self, from: Data(mixed.utf8)))
        XCTAssertEqual(b.mentions, [FSMention(userId: "b", start: 3, length: 2)])
    }

    func test_fsMessage_cachedJSONWithoutMentions_decodes() throws {
        let json = #"{"id":"a","text":"t","mine":false,"sender":"s","timestamp":"ts"}"#
        XCTAssertNil(try JSONDecoder().decode(FSMessage.self, from: Data(json.utf8)).mentions)
    }

    func test_fsMessage_roundTripsMentions() throws {
        var m = FSMessage(id: "a", text: "@Bo", mine: true, sender: "", timestamp: "t")
        m.mentions = [FSMention(userId: "u", start: 0, length: 3, username: "Bo")]
        let back = try JSONDecoder().decode(FSMessage.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.mentions, m.mentions)
    }

    func test_frames_parseMentions_threadRestoreAndLive() {
        let ment: [[String: Any]] = [["user_id": "u", "start": 4, "length": 4, "username": "Ann"]]
        let t = FSMessage(threadFrame: ["id": "x", "thread_id": "t", "sender": "bob", "body": "hey @Ann", "created_at": "c", "mentions": ment])
        XCTAssertEqual(t?.mentions?.first?.username, "Ann")
        XCTAssertEqual(t?.mentions?.first?.start, 4)
        let r = FSMessage(restoredFrame: ["id": "r", "sender": "bob", "body": "hey @Ann", "created_at": "c", "mentions": ment])
        XCTAssertEqual(r?.mentions?.count, 1)
        XCTAssertNil(FSMessage(threadFrame: ["id": "x", "thread_id": "t", "body": "hi"])?.mentions)
        XCTAssertNil(FSMention.parse(nil))
        XCTAssertNil(FSMention.parse([]))
        XCTAssertNil(FSMention.parse("x"))
        XCTAssertNil(FSMention.parse([["user_id": "u", "start": "4", "length": 4]]), "string-as-number skipped")
        XCTAssertEqual(FSMention.parse(ment)?.count, 1)
    }

    func test_mentionPush_payloadIsNotHandledBySocialRouting() {
        // The mention push keeps action "message"; the extra "mention" bool is
        // ignored by tap handling (which reads only action/group_id/thread_id).
        XCTAssertFalse(SocialPushRouting.route(userInfo: ["action": "message", "group_id": "g1", "mention": true]))
        XCTAssertFalse(SocialPushRouting.route(userInfo: ["action": "thread_message", "group_id": "g1", "thread_id": "t", "mention": true]))
    }

    func test_membersResponse_decodes() throws {
        let json = #"{"members":[{"user_id":"U1","username":"Matthew","extra":1}],"future":true}"#
        let resp = try JSONDecoder().decode(FSMentionMembersResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.members.first?.username, "Matthew")
    }

    func test_capabilities_chatMentions_failsClosed() throws {
        let on = #"{"features":{"chat_mentions":true},"terms_current":true}"#
        XCTAssertTrue(try JSONDecoder().decode(FSCapabilities.self, from: Data(on.utf8)).chatMentionsEnabled)
        let off = #"{"features":{"chat_mentions":false},"terms_current":true}"#
        XCTAssertFalse(try JSONDecoder().decode(FSCapabilities.self, from: Data(off.utf8)).chatMentionsEnabled)
        XCTAssertFalse(FSCapabilities.allOff.chatMentionsEnabled)
    }
}
