// VerseReactionsTests.swift -- testing gate, task 20261009-verse-reactions, step 5.
//
// 1. FSVerseHighlight decode: plain "#hex" string and {color, emoji} object,
//    null emoji, missing emoji, malformed rejected.
// 2. FSHighlightSearchResult decodes `emoji` (present / null / absent).
// 3. NetworkService.fetchHighlightsWithReactions (URLProtocol stub): sends
//    ?include_emoji=true, decodes both server shapes.
// 4. VerseReactionEmoji mirrors the backend allowlist (10, distinct, ordered).
// 5. FSCapabilities flag gating for `verse_reactions` (fail-closed).
// 6. BibleViewModel optimistic reaction state: react, toggle off, switch emoji,
//    keep real highlight color, rollback on failure, plain highlight clears
//    emoji, load keeps cache on failure, load populates reactions.
// 7. Source pins for BibleReaderView / search row wiring and accessibility.

import XCTest
@testable import FellowScript

// MARK: - seam on the shared throwing test service (serialized run only)

private enum VRSeam {
    static var fetchResult: [String: FSVerseHighlight]?
    static var fetchError: Error?
    static var saveReactionError: Error?
    static var reactionCalls: [(key: String, color: String?, emoji: String)] = []
    static var clearCalls: [String] = []
    static var plainSaves: [(key: String, color: String)] = []
    static func reset() {
        fetchResult = nil; fetchError = nil; saveReactionError = nil
        reactionCalls = []; clearCalls = []; plainSaves = []
    }
}

extension ThrowingTestDataService {
    func fetchHighlightsWithReactions(userId: String) async throws -> [String: FSVerseHighlight] {
        if let e = VRSeam.fetchError { throw e }
        return VRSeam.fetchResult ?? [:]
    }
    func saveVerseReaction(userId: String, book: String, chapter: Int, verse: Int, color: String?, emoji: String) async throws {
        VRSeam.reactionCalls.append(("\(book)-\(chapter)-\(verse)", color, emoji))
        if let e = VRSeam.saveReactionError { throw e }
    }
}

private struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

// MARK: - decode + network

final class VerseReactionDecodeTests: XCTestCase {
    private func dec<T: Decodable>(_ t: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(t, from: Data(json.utf8))
    }

    func test_verseHighlight_plainHexString() throws {
        let m = try dec([String: FSVerseHighlight].self, ##"{"John-3-16":"#FFD60A"}"##)
        XCTAssertEqual(m["John-3-16"], FSVerseHighlight(color: "#FFD60A", emoji: nil))
    }

    func test_verseHighlight_objectWithEmoji() throws {
        let m = try dec([String: FSVerseHighlight].self, ##"{"John-3-16":{"color":"#8E8E93","emoji":"❤️"}}"##)
        XCTAssertEqual(m["John-3-16"]?.emoji, "\u{2764}\u{FE0F}")
        XCTAssertEqual(m["John-3-16"]?.color, "#8E8E93")
    }

    func test_verseHighlight_nullAndMissingEmoji() throws {
        let m = try dec([String: FSVerseHighlight].self, ##"{"a":{"color":"#111111","emoji":null},"b":{"color":"#222222"}}"##)
        XCTAssertNil(m["a"]?.emoji)
        XCTAssertNil(m["b"]?.emoji)
        XCTAssertEqual(m["b"]?.color, "#222222")
    }

    func test_verseHighlight_malformedThrows() {
        XCTAssertThrowsError(try dec([String: FSVerseHighlight].self, #"{"a":{"emoji":"x"}}"#))
        XCTAssertThrowsError(try dec([String: FSVerseHighlight].self, #"{"a":5}"#))
    }

    func test_searchResult_emojiPresentNullAbsent() throws {
        let base = ##""owner_id":"f","owner_username":"fr","is_self":false,"book":"John","chapter":3,"verse":16,"color":"#8E8E93","verse_text":"t","timestamp":null"##
        let a = try dec(FSHighlightSearchResult.self, "{\(base),\"key\":\"John-3-16\",\"emoji\":\"\u{1F525}\"}")
        let b = try dec(FSHighlightSearchResult.self, "{\(base),\"key\":\"John-3-16\",\"emoji\":null}")
        let c = try dec(FSHighlightSearchResult.self, "{\(base),\"key\":\"John-3-16\"}")
        XCTAssertEqual(a.emoji, "\u{1F525}")
        XCTAssertNil(b.emoji)
        XCTAssertNil(c.emoji, "an older server omitting the key must still decode")
    }
}

final class VerseReactionNetworkTests: XCTestCase {
    override class func setUp() { super.setUp(); URLProtocol.registerClass(PagingStubURLProtocol.self) }
    override class func tearDown() { URLProtocol.unregisterClass(PagingStubURLProtocol.self); super.tearDown() }
    override func setUp() { PagingStubURLProtocol.reset() }

    private let route = "/api/notes/highlight/u1"

    func test_fetchWithReactions_sendsIncludeEmoji_andDecodesObjectShape() async throws {
        PagingStubURLProtocol.routes[route] = (200, ##"{"John-3-16":{"color":"#8E8E93","emoji":"\##u{1F64F}"},"Gen-1-1":{"color":"#FFD60A","emoji":null}}"##)
        let m = try await NetworkService.shared.fetchHighlightsWithReactions(userId: "u1")
        XCTAssertTrue(PagingStubURLProtocol.urls.last?.contains("include_emoji=true") == true)
        XCTAssertEqual(m["John-3-16"]?.emoji, "\u{1F64F}")
        XCTAssertNil(m["Gen-1-1"]?.emoji)
        XCTAssertEqual(m["Gen-1-1"]?.color, "#FFD60A")
    }

    func test_fetchWithReactions_oldServerPlainShape_stillDecodes() async throws {
        PagingStubURLProtocol.routes[route] = (200, ##"{"John-3-16":"#FFD60A"}"##)
        let m = try await NetworkService.shared.fetchHighlightsWithReactions(userId: "u1")
        XCTAssertEqual(m["John-3-16"], FSVerseHighlight(color: "#FFD60A", emoji: nil))
    }

    func test_fetchWithReactions_serverError_throwsNotEmpty() async {
        PagingStubURLProtocol.routes[route] = (500, #"{"detail":"x"}"#)
        do {
            _ = try await NetworkService.shared.fetchHighlightsWithReactions(userId: "u1")
            XCTFail("a 5xx must throw, not look like zero highlights")
        } catch {}
    }

    func test_plainFetchHighlights_unchangedShape() async throws {
        PagingStubURLProtocol.routes[route] = (200, ##"{"John-3-16":"#FFD60A"}"##)
        let m = try await NetworkService.shared.fetchHighlights(userId: "u1")
        XCTAssertEqual(m, ["John-3-16": "#FFD60A"])
        XCTAssertFalse(PagingStubURLProtocol.urls.last?.contains("include_emoji") == true)
    }
}

// MARK: - allowlist mirror + flag

final class VerseReactionAllowlistTests: XCTestCase {
    func test_matchesBackendAllowlist_tenDistinctInOrder() {
        let backend = ["\u{2764}\u{FE0F}", "\u{1F64F}", "\u{1F525}", "\u{1F44D}", "\u{1F622}",
                       "\u{1F62E}", "\u{2728}", "\u{1F4D6}", "\u{1F64C}", "\u{1F4A1}"]
        XCTAssertEqual(VerseReactionEmoji.allEmoji, backend)
        XCTAssertEqual(Set(VerseReactionEmoji.allEmoji).count, 10)
    }

    func test_quickSet_isSubsetOfAllowlist_andNamed() {
        XCTAssertEqual(VerseReactionEmoji.quick.count, 5)
        for e in VerseReactionEmoji.quick { XCTAssertTrue(VerseReactionEmoji.allEmoji.contains(e)) }
        for e in VerseReactionEmoji.allEmoji { XCTAssertNotEqual(VerseReactionEmoji.name(for: e), "reaction", "\(e) needs a VoiceOver name") }
        XCTAssertEqual(VerseReactionEmoji.name(for: "\u{1F600}"), "reaction", "unknown server emoji falls back, never crashes")
    }

    func test_constants() {
        XCTAssertEqual(VerseReactionEmoji.flagName, "verse_reactions")
        XCTAssertEqual(VerseReactionEmoji.neutralColor, "#8E8E93")
    }

    func test_flag_failClosed_andOnlyWhenTrue() throws {
        XCTAssertFalse(FSCapabilities.allOff.isEnabled(VerseReactionEmoji.flagName))
        let off = try JSONDecoder().decode(FSCapabilities.self, from: Data(#"{"features":{"verse_reactions":false},"terms_current":true}"#.utf8))
        XCTAssertFalse(off.isEnabled(VerseReactionEmoji.flagName))
        let missing = try JSONDecoder().decode(FSCapabilities.self, from: Data(#"{"features":{},"terms_current":true}"#.utf8))
        XCTAssertFalse(missing.isEnabled(VerseReactionEmoji.flagName))
        let on = try JSONDecoder().decode(FSCapabilities.self, from: Data(#"{"features":{"verse_reactions":true},"terms_current":true}"#.utf8))
        XCTAssertTrue(on.isEnabled(VerseReactionEmoji.flagName))
    }
}

// MARK: - view model

@MainActor
final class VerseReactionViewModelTests: XCTestCase {
    private let heart = "\u{2764}\u{FE0F}", fire = "\u{1F525}"

    private func makeVM(svc: ThrowingTestDataService = ThrowingTestDataService()) -> BibleViewModel {
        VRSeam.reset()
        let vm = BibleViewModel()
        vm.service = svc
        return vm
    }
    private var key: (BibleViewModel) -> String { { "\($0.curBook)-\($0.curChapter)-5" } }
    private func settle() async { try? await Task.sleep(nanoseconds: 150_000_000) }

    func test_react_optimistic_neutralColor_andSendsNoColor() async {
        let vm = makeVM(); let k = key(vm)
        vm.persistReaction(verse: 5, emoji: heart, userId: "u")
        XCTAssertEqual(vm.reactions[k], heart)
        XCTAssertEqual(vm.highlights[k], VerseReactionEmoji.neutralColor)
        XCTAssertEqual(vm.reaction(verse: 5), heart)
        await settle()
        XCTAssertEqual(VRSeam.reactionCalls.count, 1)
        XCTAssertNil(VRSeam.reactionCalls[0].color)
        XCTAssertEqual(VRSeam.reactionCalls[0].emoji, heart)
        XCTAssertNil(vm.saveError)
    }

    func test_react_keepsExistingRealHighlightColor() async {
        let vm = makeVM(); let k = key(vm)
        vm.highlights[k] = "#FFD60A"
        vm.persistReaction(verse: 5, emoji: fire, userId: "u")
        XCTAssertEqual(vm.highlights[k], "#FFD60A")
        await settle()
        XCTAssertEqual(VRSeam.reactionCalls.first?.color, "#FFD60A")
    }

    func test_switchEmoji_replaces() async {
        let vm = makeVM(); let k = key(vm)
        vm.persistReaction(verse: 5, emoji: heart, userId: "u")
        vm.persistReaction(verse: 5, emoji: fire, userId: "u")
        XCTAssertEqual(vm.reactions[k], fire)
        await settle()
        XCTAssertEqual(VRSeam.reactionCalls.map(\.emoji), [heart, fire])
    }

    func test_sameEmojiAgain_togglesOff_emojiOnlyVerseClearedEntirely() async {
        let vm = makeVM(); let k = key(vm)
        vm.persistReaction(verse: 5, emoji: heart, userId: "u")
        await settle()
        vm.persistReaction(verse: 5, emoji: heart, userId: "u")
        XCTAssertNil(vm.reactions[k])
        XCTAssertNil(vm.highlights[k], "emoji-only verse leaves no neutral highlight behind")
        await settle()
        XCTAssertEqual(VRSeam.reactionCalls.count, 1, "toggle-off must not POST another reaction")
    }

    func test_removeReaction_keepsRealColor_resavedAsPlain() async {
        let vm = makeVM(); let k = key(vm)
        vm.highlights[k] = "#30D158"; vm.reactions[k] = heart
        vm.persistRemoveReaction(verse: 5, userId: "u")
        XCTAssertNil(vm.reactions[k])
        XCTAssertEqual(vm.highlights[k], "#30D158")
        await settle()
        XCTAssertNil(vm.saveError)
    }

    func test_removeReaction_noReaction_isNoOp() async {
        let vm = makeVM()
        vm.persistRemoveReaction(verse: 5, userId: "u")
        await settle()
        XCTAssertTrue(vm.highlights.isEmpty && vm.reactions.isEmpty)
    }

    func test_react_failure_rollsBack_andSurfacesError() async {
        let vm = makeVM(); let k = key(vm)
        VRSeam.saveReactionError = Boom()
        vm.persistReaction(verse: 5, emoji: heart, userId: "u")
        XCTAssertEqual(vm.reactions[k], heart)
        await settle()
        XCTAssertNil(vm.reactions[k]); XCTAssertNil(vm.highlights[k])
        XCTAssertEqual(vm.saveError, "boom")
    }

    func test_react_failure_restoresPreviousReactionAndColor() async {
        let vm = makeVM(); let k = key(vm)
        vm.highlights[k] = "#FFD60A"; vm.reactions[k] = heart
        VRSeam.saveReactionError = Boom()
        vm.persistReaction(verse: 5, emoji: fire, userId: "u")
        await settle()
        XCTAssertEqual(vm.reactions[k], heart)
        XCTAssertEqual(vm.highlights[k], "#FFD60A")
    }

    func test_removeReaction_failure_restores() async {
        let svc = ThrowingTestDataService()
        svc.clearHighlightError = Boom()
        let vm = makeVM(svc: svc); let k = key(vm)
        vm.highlights[k] = VerseReactionEmoji.neutralColor; vm.reactions[k] = heart
        vm.persistRemoveReaction(verse: 5, userId: "u")
        XCTAssertNil(vm.reactions[k])
        await settle()
        XCTAssertEqual(vm.reactions[k], heart)
        XCTAssertEqual(vm.highlights[k], VerseReactionEmoji.neutralColor)
        XCTAssertNotNil(vm.saveError)
    }

    func test_plainHighlight_clearsEmoji_andFailureRestoresIt() async {
        let svc = ThrowingTestDataService()
        let vm = makeVM(svc: svc); let k = key(vm)
        vm.reactions[k] = heart; vm.highlights[k] = VerseReactionEmoji.neutralColor
        vm.persistHighlight(verse: 5, color: "#FFD60A", userId: "u")
        XCTAssertNil(vm.reactions[k]); XCTAssertEqual(vm.highlights[k], "#FFD60A")
        await settle()
        XCTAssertNil(vm.reactions[k])

        let bad = ThrowingTestDataService(); bad.saveHighlightError = Boom()
        let vm2 = makeVM(svc: bad)
        vm2.reactions[k] = heart; vm2.highlights[k] = VerseReactionEmoji.neutralColor
        vm2.persistHighlight(verse: 5, color: "#FFD60A", userId: "u")
        await settle()
        XCTAssertEqual(vm2.reactions[k], heart, "failed plain highlight must restore the reaction")
        XCTAssertEqual(vm2.highlights[k], VerseReactionEmoji.neutralColor)
    }

    func test_clearHighlight_dropsEmoji_failureRestores() async {
        let svc = ThrowingTestDataService(); svc.clearHighlightError = Boom()
        let vm = makeVM(svc: svc); let k = key(vm)
        vm.reactions[k] = heart; vm.highlights[k] = "#FFD60A"
        vm.persistClearHighlight(verse: 5, userId: "u")
        XCTAssertNil(vm.reactions[k]); XCTAssertNil(vm.highlights[k])
        await settle()
        XCTAssertEqual(vm.reactions[k], heart); XCTAssertEqual(vm.highlights[k], "#FFD60A")
    }

    func test_load_populatesHighlightsAndReactions() async {
        let vm = makeVM()
        VRSeam.fetchResult = ["John-3-16": FSVerseHighlight(color: "#8E8E93", emoji: heart),
                              "Gen-1-1": FSVerseHighlight(color: "#FFD60A")]
        await vm.load(service: vm.service, userId: "u-\(UUID().uuidString)")
        XCTAssertEqual(vm.reactions, ["John-3-16": heart])
        XCTAssertEqual(vm.highlights["Gen-1-1"], "#FFD60A")
    }

    func test_load_failure_keepsCachedState() async {
        let vm = makeVM()
        vm.highlights["John-3-16"] = "#8E8E93"; vm.reactions["John-3-16"] = heart
        VRSeam.fetchError = Boom()
        await vm.load(service: vm.service, userId: "u-\(UUID().uuidString)")
        XCTAssertEqual(vm.reactions["John-3-16"], heart)
        XCTAssertEqual(vm.highlights["John-3-16"], "#8E8E93")
    }
}

// MARK: - source pins (private SwiftUI state is out of reach of a render)

final class VerseReactionSourcePinTests: XCTestCase {
    private func readSource(_ rel: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(rel)
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_reader_reactionsGatedBehindFlag_andExistingMenuKept() throws {
        let s = try readSource("FellowScript/Bible/BibleReaderView.swift")
        XCTAssertTrue(s.contains("capabilities.isEnabled(VerseReactionEmoji.flagName)"))
        XCTAssertTrue(s.contains("reactionEmoji: reactionsOn ? vm.reaction(verse: v.num) : nil"),
                      "flag off must not render any badge")
        XCTAssertTrue(s.contains("if reactionsOn {\n            ReactionMenuSection("), "menu row only when flag on")
        XCTAssertTrue(s.contains("onMore: { moreReactionsVerse = verse }"))
        XCTAssertTrue(s.contains("ReactionPickerSheet(emojis: VerseReactionEmoji.allEmoji"))
        XCTAssertTrue(s.contains(#".accessibilityLabel("Add verse \(verse) to note")"#), "Add to Note untouched")
        XCTAssertTrue(s.contains("Copy") && s.contains("Share"))
    }

    func test_reader_accessibility() throws {
        let s = try readSource("FellowScript/Bible/BibleReaderView.swift")
        XCTAssertTrue(s.contains(#"label += ", reacted with \(VerseReactionEmoji.name(for: emoji))""#))
        XCTAssertTrue(s.contains(#".accessibilityLabel("Remove reaction from verse \(verse)")"#))
        XCTAssertTrue(s.contains("reactionAccessibilityActions("), "VoiceOver custom actions")
        XCTAssertTrue(s.contains("reduceMotion"), "badge animation is Reduce Motion gated")
        XCTAssertTrue(s.contains("badgeSize"), "badge scales with Dynamic Type")
        XCTAssertTrue(s.contains(".accessibilityHidden(true)"))
    }

    func test_reader_neutralSentinelNeverTinted() throws {
        let s = try readSource("FellowScript/Bible/BibleReaderView.swift")
        XCTAssertTrue(s.contains("hex.uppercased() == VerseReactionEmoji.neutralColor"))
    }

    func test_network_postBodyOmitsColorWhenNil_andOnlyReactionPathSendsEmoji() throws {
        let s = try readSource("FellowScript/Services/NetworkService+Highlights.swift")
        XCTAssertTrue(s.contains("if let color { body[\"color\"] = color }"))
        XCTAssertTrue(s.contains(#""emoji": emoji"#))
        // plain saveHighlight body must stay exactly the old shape
        XCTAssertTrue(s.contains(#"jsonObject: ["book": book, "chapter": chapter, "verse": verse, "color": color])"#))
    }

    func test_searchRow_showsEmojiWithSpokenName_decorativeGlyphHidden() throws {
        let s = try readSource("FellowScript/Notes/NotesListView+HighlightSearch.swift")
        XCTAssertTrue(s.contains("result.emoji"))
        XCTAssertTrue(s.contains(#"parts.append("reacted with \(VerseReactionEmoji.name(for: emoji))")"#))
        XCTAssertTrue(s.contains(".accessibilityLabel(reactionLabel)"))
    }
}
