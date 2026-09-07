// FriendActivityAvatarRowNudgeStatesWiringTests.swift — testing gate coverage
// for task 20260906-friend-activity-avatar-row.
//
// frontend.json's summary explicitly called out, as "out of scope / the
// sibling task's job", that DashboardView.swift does not yet pass
// `nudgeStates:` into `FriendActivityHeroCard`. This file checks whether that
// is actually true (nothing left to wire — the sibling 20260906-friend-nudges
// task already did it) or a real, functional integration gap this task
// introduced by adding a tappable nudge control without ever feeding it live
// state.
//
// Findings, proven below:
//
//   1. FriendActivityHeroCard itself is wired correctly: given a real
//      `nudgeStates` map, the tile's nudge button correctly reflects
//      `.sending` (disabled, spinner) vs `.idle` (enabled, paper-plane) —
//      the component-level contract from design-spec.md §2 is honored.
//   2. But DashboardView's *only* real call site never supplies
//      `nudgeStates:` at all (source-pinned below), so the parameter
//      silently defaults to `[:]` in production. Because `friendTile`/
//      `nudgeControl` both compute `nudgeStates[entry.id] ?? .idle`, this
//      means every avatar-tile nudge button renders and behaves as
//      permanently `.idle` in the real running app, regardless of
//      `DashboardViewModel.friendNudgeStates`'s real, live value.
//   3. That is not a graceful "just shows idle" default — `onNudge` really
//      does call the live `DashboardViewModel.sendNudge`/network path (also
//      proven below), and `nudgeIsInteractive(.idle) == true`, so the button
//      stays enabled forever. A user who taps it, gets a real send, and taps
//      again (or taps again after a `.rateLimited`/`.failed` result) fires
//      *another* real nudge send — sendNudge's own re-entrancy guard
//      (`friendNudgeStates[friendId] != .sending`) only blocks a second
//      concurrent in-flight tap, not a second tap after the first send has
//      already resolved. There is also never a spinner, checkmark, or error
//      pulse — the control looks and behaves as if nothing happened, on
//      every tap, forever.
//
// This is a real functional gap in shipped, user-facing behavior, not a
// deferred nice-to-have — bounced back to frontend rather than passed
// through.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

@MainActor
final class FriendActivityAvatarRowNudgeStatesWiringTests: XCTestCase {

    private func singleFriendFeed(id: String = "friend-a", username: String = "Ann") -> FSFriendActivityFeed {
        FSFriendActivityFeed(
            friends_active: [
                FSFriendActivityEntry(friend_id: id, username: username, last_active_at: nil, note_preview: nil)
            ],
            check_in_candidates: []
        )
    }

    private func findNudgeButton(_ sut: FriendActivityHeroCard, username: String) throws -> InspectableView<ViewType.Button> {
        try sut.inspect().find(ViewType.Button.self, where: { button in
            (try? button.accessibilityLabel().string().contains(username)) ?? false
                && (try? button.accessibilityLabel().string().contains("Nudge")) ?? false
        })
    }

    // MARK: 1 — the component itself DOES honor nudgeStates when it's actually supplied

    func test_friendActivityHeroCard_nudgeControl_reflectsSendingState_whenNudgeStatesIsSupplied() throws {
        let feed = singleFriendFeed()
        let sending = FriendActivityHeroCard(feed: feed, onOpenFriend: { _ in }, nudgeStates: ["friend-a": .sending])
        let idle = FriendActivityHeroCard(feed: feed, onOpenFriend: { _ in }, nudgeStates: [:])

        let sendingButton = try findNudgeButton(sending, username: "Ann")
        let idleButton = try findNudgeButton(idle, username: "Ann")

        XCTAssertTrue(try sendingButton.isDisabled(),
                       "with a real .sending entry in nudgeStates, the tile's nudge control must be disabled -- " +
                       "proving the component contract itself is correct when actually fed live state")
        XCTAssertFalse(try idleButton.isDisabled(),
                        "an .idle/missing entry must stay tappable -- sanity check that disabled isn't just always true")
    }

    func test_friendActivityHeroCard_nudgeControl_reflectsSentState_becomesNonInteractive_whenSupplied() throws {
        let feed = singleFriendFeed()
        let sent = FriendActivityHeroCard(feed: feed, onOpenFriend: { _ in }, nudgeStates: ["friend-a": .sent])

        let sentButton = try findNudgeButton(sent, username: "Ann")
        XCTAssertTrue(try sentButton.isDisabled(),
                       "once a real send has resolved to .sent, the control must go non-interactive so a friend " +
                       "already nudged can't be silently re-nudged by an extra tap -- true whenever nudgeStates " +
                       "actually reaches this view with the real value")
    }

    // MARK: 2 — but DashboardView's real call site never supplies it

    private func readSource(_ relativePath: String) throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }

    func test_dashboardView_friendActivityHeroCardCallSite_mustPassLiveFriendNudgeStates() throws {
        let source = try readSource("FellowScript/Dashboard/DashboardView.swift")

        // Isolate the actual FriendActivityHeroCard(...) call-site block (up
        // to its closing `)` at the same indentation as its own onNudge/
        // isLoadingNotePreview siblings), not FriendActivityHeroCard's own
        // struct declaration in DashboardComponents.swift -- this must be
        // read from DashboardView.swift specifically, the file this
        // regression is actually about.
        guard let callSiteRange = source.range(of: "FriendActivityHeroCard(") else {
            XCTFail("DashboardView.swift must instantiate FriendActivityHeroCard at all")
            return
        }
        guard let closeParenRange = source.range(of: "\n                    )", range: callSiteRange.upperBound..<source.endIndex) else {
            XCTFail("could not locate the end of the FriendActivityHeroCard(...) call site to inspect its arguments")
            return
        }
        let callSite = String(source[callSiteRange.lowerBound..<closeParenRange.upperBound])

        XCTAssertTrue(callSite.contains("nudgeStates:"),
                       "DashboardView's FriendActivityHeroCard(...) call site must pass nudgeStates: (e.g. " +
                       "vm.friendNudgeStates) -- without it, nudgeStates silently defaults to [:] in the real " +
                       "running app, so every avatar-tile nudge button renders/behaves as permanently .idle " +
                       "regardless of DashboardViewModel.friendNudgeStates's real, live value. This is what " +
                       "frontend.json flagged and called the sibling task's job; DashboardViewModel.friendNudgeStates " +
                       "already exists and is already kept live by DashboardViewModel.sendNudge (delivered by the " +
                       "sibling 20260906-friend-nudges task) -- the only missing piece is this one call-site argument, " +
                       "which is this task's own file/call site to wire, not a separate task's remaining work.")
    }

    // MARK: 3 — proving onNudge really does reach the live send path (so this
    // is a *state-feedback* gap, not a "the button does nothing" gap)

    func test_onNudge_reallyDrivesDashboardViewModelSendNudge_realNetworkPathNotANoOp() async {
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        let userId = "user-\(UUID().uuidString)"
        service.fetchFriendActivityResult = singleFriendFeed()
        await vm.load(service: service, userId: userId)

        service.sendNudgeResult = .sent
        await vm.sendNudge(to: "friend-a", userId: userId)

        XCTAssertEqual(service.sendNudgeCallCount, 1,
                       "DashboardViewModel.sendNudge (what the call site's onNudge closure invokes) must reach the " +
                       "real service.sendNudge -- confirms the tap path is genuinely live, not dead wiring; the bug " +
                       "is specifically that its resulting state never reaches the view, not that the tap itself " +
                       "silently does nothing")
        XCTAssertEqual(vm.friendNudgeStates["friend-a"], .sent)
    }

    // MARK: 4 — without nudgeStates wired, a tap AFTER a resolved send is not blocked at the UI layer

    func test_withoutNudgeStatesWired_uiLayerNeverBlocksARepeatTapAfterAResolvedSend() async {
        let vm = DashboardViewModel()
        let service = ThrowingTestDataService()
        let userId = "user-\(UUID().uuidString)"
        service.fetchFriendActivityResult = singleFriendFeed()
        await vm.load(service: service, userId: userId)

        service.sendNudgeResult = .sent
        await vm.sendNudge(to: "friend-a", userId: userId)
        XCTAssertEqual(vm.friendNudgeStates["friend-a"], .sent, "sanity: the model layer does know this friend was already nudged")

        // This is exactly what the real, unwired call site renders: a
        // FriendActivityHeroCard given no nudgeStates: argument at all.
        let unwired = FriendActivityHeroCard(feed: vm.friendActivity, onOpenFriend: { _ in })
        let button = try? findNudgeButton(unwired, username: "Ann")

        XCTAssertNotNil(button)
        XCTAssertFalse(try button?.isDisabled() ?? true,
                        "regression proof: even though the model already knows this friend was nudged (.sent), " +
                        "the real call site's missing nudgeStates: wiring means the tile's nudge control still " +
                        "renders fully enabled -- a repeat tap would fire another real nudge send with zero visual " +
                        "indication anything happened the first time")
    }
}
