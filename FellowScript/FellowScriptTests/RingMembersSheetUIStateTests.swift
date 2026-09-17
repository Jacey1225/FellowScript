// RingMembersSheetUIStateTests.swift — testing-gate coverage for task
// 20260916-call-ring-members, re-entry pass after the backend
// (RING_FEATURE_ENABLED/RING_COOLDOWN_MINUTES config-boot fix) and frontend
// (ThrowingTestDataService.ringMembers compile fix) bounces were both
// closed. api/tests/test_ring_members.py (this task's prior testing pass)
// already covers the full backend charter (authorization, DM mutual-
// friendship/block verification, chime_meeting_id live-call gate,
// cross-session ring_cooldowns) -- this file is the iOS half of step 5's
// charter that could not be added last time because FellowScriptTests
// itself failed to compile: RingMembersSheet's per-row UI-state machine
// (default/selected/sending/sent/rateLimited/error("...")), driven by the
// exact `POST /devotions/ring` response shape (`RingResult.sent`/`.reason`)
// backend actually returns.
//
// RingMembersSheet has no separate view-model class -- `rowStates`/
// `candidates`/`hasAttemptedRing` are `@State` local to the View struct
// itself, and its "Ring" action is a `PillButton` inside a `ToolbarItem`
// carrying `.suppressAutomaticGlassChrome()`, which ViewInspector 0.10.3
// cannot traverse to reach the button by any route (the same limitation
// NoteDetailView's editAction()/closeAction() and this repo's other
// toolbar-bound-action tests already document). This file follows that
// exact established precedent:
//   - `RingMembersSheet.sendRing()` was exposed `internal` (was `private`)
//     for this reason alone -- it's the identical closure the toolbar
//     button calls, so calling it directly still exercises the real
//     production send path, just without simulating the tap itself.
//   - A `Inspection<Self>` "Approach #2" test hook (Utils/Inspection.swift,
//     `#if DEBUG`-gated, mirrors NoteDetailView/BlockedUsersView's identical
//     seam) was added so `@State` that settles after a real async gap (the
//     `.task`-driven roster load on mount, then `sendRing()`'s own awaited
//     network call) can be observed reliably.
// Row selection itself (`toggle(_:)`, bound to each row's plain
// `.onTapGesture`, NOT inside the toolbar) needed no such change --
// ViewInspector's ordinary tap-simulation already reaches it, exactly like
// ChipToggleTests' pre-existing `.callOnTapGesture()` technique.
//
// Every send-path test below drives selection + `sendRing()` + assertion
// inside a SINGLE `inspection.inspect(after:)` callback, then polls
// (`settledLabel`, short real sleeps inside that one async callback) until
// the row leaves `Sending` rather than asserting against a single guessed
// fixed delay -- a shared CI/simulator box under load can legitimately take
// longer than any one fixed guess for an awaited call to resolve, and this
// polls-to-completion approach is immune to that instead of guessing a
// bigger number and still occasionally flaking.
//
// `ThrowingTestDataService.ringMembers` (AppStateAuthAccountTests.swift) was
// extended in this same pass with a settable `ringMembersResult` (mirroring
// `sendNudgeResult`'s exact shape) plus `lastRingMembers*` call-observability,
// since the frontend-added stub only forwarded to MockDataService's fixed
// `{sent: true}`-for-everyone stub -- not enough to drive
// rate-limited/error/no-active-call/not-a-member per-row outcomes.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

@MainActor
final class RingMembersSheetUIStateTests: XCTestCase {

    override func tearDown() {
        // sentRingTargets is a shared, call-scoped singleton (CallController.shared)
        // -- reset between tests so an earlier test's "sent" row doesn't leak
        // into a later test's fresh roster load (RingMembersSheet.loadRoster()
        // seeds a row `.sent` if its id is already in this set).
        CallController.shared.sentRingTargets = []
        super.tearDown()
    }

    // MARK: - Fixtures

    /// `group-abc` matches MockDataService.fetchContacts' fixed fixture
    /// (`users: [userId, "friend-001", "friend-002"]`) -- ThrowingTestDataService
    /// forwards fetchContacts straight to that fixture, so this is the real
    /// roster RingMembersSheet's group-branch resolves against.
    private func groupSession(id: String = "session-1", participants: [String] = []) -> FSSession {
        FSSession(id: id, title: "Ring test", group_id: "group-abc",
                   creator_id: "user-me", participants: participants)
    }

    private func dmSession(id: String = "session-dm", meId: String, otherId: String) -> FSSession {
        FSSession(id: id, title: "Ring test DM", group_id: "\(meId)|\(otherId)",
                   creator_id: meId, participants: [meId, otherId])
    }

    private func makeService() -> ThrowingTestDataService {
        let service = ThrowingTestDataService()
        // fetchUser is userId-agnostic in MockDataService (always returns the
        // same mockUser) -- override per-id so Alice/Bob are independently
        // distinguishable rows rather than two identical names.
        service.fetchUserResultsById = [
            "friend-001": FSUser(user_id: "friend-001", username: "Alice", email: "alice@example.com"),
            "friend-002": FSUser(user_id: "friend-002", username: "Bob", email: "bob@example.com"),
        ]
        return service
    }

    private func findRowHStack(
        _ view: InspectableView<ViewType.View<RingMembersSheet>>, named name: String
    ) throws -> InspectableView<ViewType.HStack> {
        try view.find(ViewType.HStack.self, where: { hstack in
            (try? hstack.accessibilityLabel().string())?.hasPrefix("\(name).") ?? false
        })
    }

    private func rowLabel(
        _ view: InspectableView<ViewType.View<RingMembersSheet>>, named name: String
    ) throws -> String {
        try findRowHStack(view, named: name).accessibilityLabel().string()
    }

    /// Polls (real short sleeps, inside the caller's own async inspection
    /// callback) until `name`'s row leaves the transient `Sending` state, or
    /// `maxAttempts * 100ms` elapses -- immune to CI/simulator load making
    /// any single fixed-delay guess occasionally too short.
    private func settledLabel(
        _ view: InspectableView<ViewType.View<RingMembersSheet>>, named name: String, maxAttempts: Int = 60
    ) async throws -> String {
        var label = try rowLabel(view, named: name)
        var attempts = 0
        while label.hasSuffix("Sending") && attempts < maxAttempts {
            try await Task.sleep(nanoseconds: 100_000_000)
            label = try rowLabel(view, named: name)
            attempts += 1
        }
        return label
    }

    // MARK: 1 — Roster loads, partitions NOT YET JOINED vs ALREADY IN CALL,
    // every row starts "Not selected" (including an already-joined one --
    // design-notes.md §2/architecture's already_joined_determination: a
    // display-only, still-selectable distinction, not a security boundary).

    func test_rosterLoads_partitionsByParticipants_allRowsStartNotSelected() throws {
        let service = makeService()
        let sut = RingMembersSheet(session: groupSession(participants: ["friend-002"]), service: service, userId: "user-me")

        let exp = sut.inspection.inspect(after: 0.5) { view in
            XCTAssertNoThrow(try view.find(text: "NOT YET JOINED"))
            XCTAssertNoThrow(try view.find(text: "ALREADY IN CALL"))
            XCTAssertEqual(try self.rowLabel(view, named: "Alice"), "Alice. Not selected")
            XCTAssertEqual(try self.rowLabel(view, named: "Bob"), "Bob. Not selected",
                            "an already-joined member must still start selectable, not disabled")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 4)
    }

    // MARK: 2 — Tapping a row selects it; tapping again deselects it
    // (purely synchronous -- no network round trip, so a single callback
    // with no polling needed).

    func test_tappingRow_togglesSelectedThenBackToDefault() throws {
        let service = makeService()
        let sut = RingMembersSheet(session: groupSession(), service: service, userId: "user-me")

        let exp = sut.inspection.inspect(after: 0.5) { view in
            try self.findRowHStack(view, named: "Alice").callOnTapGesture()
            XCTAssertEqual(try self.rowLabel(view, named: "Alice"), "Alice. Selected")
            try self.findRowHStack(view, named: "Alice").callOnTapGesture()
            XCTAssertEqual(try self.rowLabel(view, named: "Alice"), "Alice. Not selected")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 4)
    }

    // MARK: 3 — Success: selected -> sending -> sent, CallController records it,
    // and the real submission carries the right session/target ids (multi-select).

    func test_sendRing_success_rendersSentState_recordsInCallController_submitsCorrectPayload() throws {
        let service = makeService()
        service.ringMembersResult = [
            "friend-001": RingResult(sent: true, reason: nil),
            "friend-002": RingResult(sent: true, reason: nil),
        ]
        let session = groupSession(id: "session-multi")
        let sut = RingMembersSheet(session: session, service: service, userId: "user-me")

        let exp = sut.inspection.inspect(after: 0.5) { view in
            try self.findRowHStack(view, named: "Alice").callOnTapGesture()
            try self.findRowHStack(view, named: "Bob").callOnTapGesture()
            XCTAssertEqual(try self.rowLabel(view, named: "Alice"), "Alice. Selected")
            XCTAssertEqual(try self.rowLabel(view, named: "Bob"), "Bob. Selected")
            try view.actualView().sendRing()

            let aliceLabel = try await self.settledLabel(view, named: "Alice")
            let bobLabel = try await self.settledLabel(view, named: "Bob")
            XCTAssertEqual(aliceLabel, "Alice. Sent")
            XCTAssertEqual(bobLabel, "Bob. Sent")
            XCTAssertTrue(CallController.shared.sentRingTargets.isSuperset(of: ["friend-001", "friend-002"]),
                          "a successful ring must be recorded so the sheet stays 'sent' across reopenings")

            XCTAssertEqual(service.lastRingMembersSessionId, "session-multi")
            XCTAssertEqual(Set(service.lastRingMembersTargetIds ?? []), ["friend-001", "friend-002"],
                           "a multi-select ring must submit every selected target in ONE request, not one call per target")
            XCTAssertEqual(service.ringMembersCallCount, 1, "multi-select ring must be a single batched call")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 8)
    }

    // MARK: 4 — Rate-limited target renders the distinct rate-limited state
    // (and remains tap-to-retry, per toggle()'s isInteractive contract).

    func test_sendRing_rateLimited_rendersRateLimitedState_andIsRetryable() throws {
        let service = makeService()
        service.ringMembersResult = ["friend-001": RingResult(sent: false, reason: "rate_limited")]
        let sut = RingMembersSheet(session: groupSession(), service: service, userId: "user-me")

        let exp = sut.inspection.inspect(after: 0.5) { view in
            try self.findRowHStack(view, named: "Alice").callOnTapGesture()
            try view.actualView().sendRing()

            let label = try await self.settledLabel(view, named: "Alice")
            XCTAssertEqual(label, "Alice. Rate limited")

            // A rate-limited row is tap-to-retry -- back to `selected`, not stuck.
            try self.findRowHStack(view, named: "Alice").callOnTapGesture()
            XCTAssertEqual(try self.rowLabel(view, named: "Alice"), "Alice. Selected",
                           "a rate-limited row must be re-selectable for a retry, per toggle()'s isInteractive contract")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 8)
    }

    // MARK: 5 — Every other per-target reason maps to its own distinct
    // caption: unreachable -> "Not reachable", send_failed -> "Couldn't
    // send", and the merged/fail-closed reasons (not_a_member, no_active_call,
    // invalid_target, and a bare unrecognized/nil reason) all degrade to the
    // same generic "Unavailable" caption -- matching apply(results:to:)'s
    // `default` branch exactly, including no_active_call/not_a_member's own
    // dedicated names in this step's charter.

    func test_sendRing_perReasonMapping_unreachableSendFailedAndMergedUnavailableReasons() throws {
        for (reason, expectedCaption) in [
            ("unreachable", "Not reachable"),
            ("send_failed", "Couldn't send"),
            ("not_a_member", "Unavailable"),
            ("no_active_call", "Unavailable"),
            ("invalid_target", "Unavailable"),
        ] {
            let service = makeService()
            service.ringMembersResult = ["friend-001": RingResult(sent: false, reason: reason)]
            let sut = RingMembersSheet(session: groupSession(), service: service, userId: "user-me")

            let exp = sut.inspection.inspect(after: 0.5) { view in
                try self.findRowHStack(view, named: "Alice").callOnTapGesture()
                try view.actualView().sendRing()

                let label = try await self.settledLabel(view, named: "Alice")
                XCTAssertEqual(label, "Alice. \(expectedCaption)",
                               "reason '\(reason)' must render caption '\(expectedCaption)'")
            }
            ViewHosting.host(view: sut)
            wait(for: [exp], timeout: 8)
            ViewHosting.expel()
        }
    }

    // MARK: 6 — A thrown network error (not a per-target reason at all --
    // e.g. the request itself never reached the server) still fails every
    // selected target closed to the same "Couldn't send" caption, never
    // leaving a row stuck in `sending` forever.

    func test_sendRing_thrownNetworkError_failsAllSelectedTargetsToCouldntSend() throws {
        let service = makeService()
        service.ringMembersError = AppError.networkError("simulated offline")
        let sut = RingMembersSheet(session: groupSession(), service: service, userId: "user-me")

        let exp = sut.inspection.inspect(after: 0.5) { view in
            try self.findRowHStack(view, named: "Alice").callOnTapGesture()
            try self.findRowHStack(view, named: "Bob").callOnTapGesture()
            try view.actualView().sendRing()

            let aliceLabel = try await self.settledLabel(view, named: "Alice")
            let bobLabel = try await self.settledLabel(view, named: "Bob")
            XCTAssertEqual(aliceLabel, "Alice. Couldn't send")
            XCTAssertEqual(bobLabel, "Bob. Couldn't send")
            XCTAssertTrue(CallController.shared.sentRingTargets.isEmpty,
                          "a thrown/failed ring must never be recorded as sent")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 8)
    }

    // MARK: 7 — Defensive: a target the response silently omits (a contract
    // violation) fails safe to "Couldn't send" rather than hanging in
    // `sending` forever (design-notes.md §4, apply(results:to:)'s own guard).

    func test_sendRing_targetMissingFromResponse_failsSafeToCouldntSend() throws {
        let service = makeService()
        service.ringMembersResult = [:] // Alice requested but absent from the response
        let sut = RingMembersSheet(session: groupSession(), service: service, userId: "user-me")

        let exp = sut.inspection.inspect(after: 0.5) { view in
            try self.findRowHStack(view, named: "Alice").callOnTapGesture()
            try view.actualView().sendRing()

            let label = try await self.settledLabel(view, named: "Alice")
            XCTAssertEqual(label, "Alice. Couldn't send")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 8)
    }

    // MARK: 8 — A `sending`/`sent` row is not interactive: tapping it again
    // mid-flight or after success must not toggle it back to `selected` or
    // trigger a second submission.

    func test_sentRow_isNoLongerTappable() throws {
        let service = makeService()
        service.ringMembersResult = ["friend-001": RingResult(sent: true, reason: nil)]
        let sut = RingMembersSheet(session: groupSession(), service: service, userId: "user-me")

        let exp = sut.inspection.inspect(after: 0.5) { view in
            try self.findRowHStack(view, named: "Alice").callOnTapGesture()
            try view.actualView().sendRing()

            let label = try await self.settledLabel(view, named: "Alice")
            XCTAssertEqual(label, "Alice. Sent")

            // Tapping a `sent` row must be a no-op -- toggle()'s own
            // isInteractive guard, proven behaviorally rather than assumed.
            try self.findRowHStack(view, named: "Alice").callOnTapGesture()
            XCTAssertEqual(try self.rowLabel(view, named: "Alice"), "Alice. Sent",
                           "a sent row must never revert to selected/default from a stray tap")
            XCTAssertEqual(service.ringMembersCallCount, 1, "no second submission should have fired")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 8)
    }

    // MARK: 9 — DM-encoded session: resolves exactly the one other party as
    // a ringable candidate (mirrors the backend's DM-pair roster shape this
    // task's security rework hardened), and rings them successfully.

    func test_dmSession_resolvesSingleOtherPartyAndCanBeRung() throws {
        let service = makeService()
        service.ringMembersResult = ["friend-001": RingResult(sent: true, reason: nil)]
        let sut = RingMembersSheet(session: dmSession(meId: "user-me", otherId: "friend-001"), service: service, userId: "user-me")

        let exp = sut.inspection.inspect(after: 0.5) { view in
            XCTAssertEqual(try self.rowLabel(view, named: "Alice"), "Alice. Not selected")
            XCTAssertThrowsError(try self.findRowHStack(view, named: "Bob"),
                                 "a DM session's roster must resolve to exactly the one other party, never a third id") { _ in }
            try self.findRowHStack(view, named: "Alice").callOnTapGesture()
            try view.actualView().sendRing()

            let label = try await self.settledLabel(view, named: "Alice")
            XCTAssertEqual(label, "Alice. Sent")
        }
        ViewHosting.host(view: sut)
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 8)
    }
}
