// WorkspaceDockLayoutTests.swift — task 20261013-ipad-adaptive-desktop-mirror (testing gate, pass 2).
// Dock model: default arrangement, move/reorder rules, last-tab guard, reopen in last dock,
// persistence (per-user isolation, corrupt/stale fallback), drop geometry, WorkspaceState intents.

import XCTest
import SwiftUI
@testable import FellowScript

@MainActor
final class WorkspaceDockLayoutTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "WorkspaceDockLayoutTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: default
    func test_default_isValid_andMatchesDesktopArrangement() {
        let l = WorkspaceDockLayout.default
        XCTAssertTrue(l.isValid)
        XCTAssertEqual(l.tabs(in: .centerTop), [.bible])
        XCTAssertEqual(l.tabs(in: .centerBottom), [.agentChat])
        XCTAssertEqual(l.tabs(in: .right), [.notes, .highlights, .messages])
        XCTAssertEqual(l.activeTab(in: .right), .notes)
        XCTAssertEqual(l.openCount, 5)
        XCTAssertTrue(l.closed.isEmpty)
    }

    // MARK: move between docks
    func test_move_toOtherDock_removesFromSource_appendsAndActivates() {
        var l = WorkspaceDockLayout.default
        XCTAssertTrue(l.move(.notes, to: .centerTop))
        XCTAssertEqual(l.tabs(in: .centerTop), [.bible, .notes])
        XCTAssertEqual(l.tabs(in: .right), [.highlights, .messages])
        XCTAssertEqual(l.activeTab(in: .centerTop), .notes)
        XCTAssertEqual(l.dock(of: .notes), .centerTop)
        XCTAssertTrue(l.isValid)
    }

    func test_move_atIndex_insertsAtThatPosition() {
        var l = WorkspaceDockLayout.default
        l.move(.messages, to: .centerTop, at: 0)
        XCTAssertEqual(l.tabs(in: .centerTop), [.messages, .bible])
    }

    func test_move_indexBeyondCount_clampsToEnd_negativeClampsToStart() {
        var l = WorkspaceDockLayout.default
        l.move(.notes, to: .centerBottom, at: 99)
        XCTAssertEqual(l.tabs(in: .centerBottom), [.agentChat, .notes])
        l.move(.highlights, to: .centerBottom, at: -5)
        XCTAssertEqual(l.tabs(in: .centerBottom), [.highlights, .agentChat, .notes])
    }

    func test_move_sourceActiveRepaired_whenActiveTabLeaves() {
        var l = WorkspaceDockLayout.default
        XCTAssertEqual(l.activeTab(in: .right), .notes)
        l.move(.notes, to: .centerTop)
        XCTAssertEqual(l.activeTab(in: .right), .highlights)
        XCTAssertTrue(l.isValid)
    }

    func test_move_lastTabOutOfDock_emptiesDock_keepsEverythingOpen() {
        var l = WorkspaceDockLayout.default
        l.move(.bible, to: .right)
        XCTAssertTrue(l.tabs(in: .centerTop).isEmpty)
        XCTAssertNil(l.activeTab(in: .centerTop))
        XCTAssertEqual(l.openCount, 5)
        XCTAssertTrue(l.isValid)
    }

    func test_move_updatesLastDock() {
        var l = WorkspaceDockLayout.default
        l.move(.notes, to: .centerBottom)
        XCTAssertEqual(l.homeDock(of: .notes), .centerBottom)
    }

    func test_move_toSameDockSamePosition_isNoOp() {
        var l = WorkspaceDockLayout.default
        // notes already first and active in .right
        let before = l
        XCTAssertFalse(l.move(.notes, to: .right, at: 0))
        XCTAssertEqual(l, before)
    }

    func test_move_toOwnDockAppend_noIndex_reordersToEnd() {
        var l = WorkspaceDockLayout.default
        XCTAssertTrue(l.move(.notes, to: .right))
        XCTAssertEqual(l.tabs(in: .right), [.highlights, .messages, .notes])
    }

    // MARK: reorder within a strip
    func test_reorder_forward_usesPreRemovalIndex() {
        var l = WorkspaceDockLayout.default
        // Drop notes after highlights: insertion index 2 in [notes, highlights, messages]
        l.move(.notes, to: .right, at: 2)
        XCTAssertEqual(l.tabs(in: .right), [.highlights, .notes, .messages])
    }

    func test_reorder_backward() {
        var l = WorkspaceDockLayout.default
        l.move(.messages, to: .right, at: 0)
        XCTAssertEqual(l.tabs(in: .right), [.messages, .notes, .highlights])
    }

    func test_nudge_laterAndEarlier() {
        var l = WorkspaceDockLayout.default
        XCTAssertTrue(l.nudge(.notes, by: 1))
        XCTAssertEqual(l.tabs(in: .right), [.highlights, .notes, .messages])
        XCTAssertTrue(l.nudge(.notes, by: -1))
        XCTAssertEqual(l.tabs(in: .right), [.notes, .highlights, .messages])
    }

    func test_nudge_atEnds_returnsFalse_noChange() {
        var l = WorkspaceDockLayout.default
        let before = l
        XCTAssertFalse(l.nudge(.notes, by: -1))
        XCTAssertFalse(l.nudge(.messages, by: 1))
        XCTAssertFalse(l.nudge(.bible, by: 1)) // only tab in its dock
        XCTAssertEqual(l, before)
    }

    func test_reorder_tracksWholeStripAcrossManyMoves_staysValid() {
        var l = WorkspaceDockLayout.default
        for (i, t) in WorkspaceTab.allCases.enumerated() {
            l.move(t, to: WorkspaceDock.allCases[i % 3], at: i % 2)
            XCTAssertTrue(l.isValid, "invalid after moving \(t)")
        }
        XCTAssertEqual(l.openCount, 5)
    }

    // MARK: close / last-tab guard / reopen
    func test_close_hidesTab_remembersDock_activeRepaired() {
        var l = WorkspaceDockLayout.default
        XCTAssertTrue(l.close(.notes))
        XCTAssertFalse(l.isOpen(.notes))
        XCTAssertTrue(l.closed.contains(.notes))
        XCTAssertEqual(l.activeTab(in: .right), .highlights)
        XCTAssertEqual(l.homeDock(of: .notes), .right)
        XCTAssertTrue(l.isValid)
    }

    func test_close_lastOpenTab_isRefused() {
        var l = WorkspaceDockLayout.default
        for t in [WorkspaceTab.bible, .agentChat, .notes, .highlights] { XCTAssertTrue(l.close(t)) }
        XCTAssertEqual(l.openCount, 1)
        let before = l
        XCTAssertFalse(l.close(.messages))
        XCTAssertEqual(l, before)
        XCTAssertTrue(l.isOpen(.messages))
        XCTAssertTrue(l.isValid)
    }

    func test_close_alreadyClosedTab_returnsFalse() {
        var l = WorkspaceDockLayout.default
        l.close(.notes)
        XCTAssertFalse(l.close(.notes))
    }

    func test_reopen_returnsToLastDock_afterMoveThenClose() {
        var l = WorkspaceDockLayout.default
        l.move(.notes, to: .centerBottom)
        l.close(.notes)
        l.reopen(.notes)
        XCTAssertEqual(l.dock(of: .notes), .centerBottom)
        XCTAssertEqual(l.activeTab(in: .centerBottom), .notes)
        XCTAssertFalse(l.closed.contains(.notes))
        XCTAssertTrue(l.isValid)
    }

    func test_activate_closedTab_reopensInLastDock() {
        var l = WorkspaceDockLayout.default
        l.move(.messages, to: .centerTop)
        l.close(.messages)
        l.activate(.messages)
        XCTAssertEqual(l.dock(of: .messages), .centerTop)
        XCTAssertEqual(l.activeTab(in: .centerTop), .messages)
    }

    func test_move_closedTab_opensItInTarget() {
        var l = WorkspaceDockLayout.default
        l.close(.highlights)
        XCTAssertTrue(l.move(.highlights, to: .centerTop))
        XCTAssertEqual(l.dock(of: .highlights), .centerTop)
        XCTAssertFalse(l.closed.contains(.highlights))
        XCTAssertTrue(l.isValid)
    }

    func test_activate_inDock_switchesActive_withoutMoving() {
        var l = WorkspaceDockLayout.default
        l.activate(.messages)
        XCTAssertEqual(l.activeTab(in: .right), .messages)
        XCTAssertEqual(l.tabs(in: .right), [.notes, .highlights, .messages])
    }

    // MARK: validity
    func test_isValid_falseWhenNothingOpen_orDuplicated() throws {
        var obj = try jsonObject(of: .default)
        obj["order"] = ["centerTop": [], "centerBottom": [], "right": []]
        obj["activeByDock"] = [String: String]()
        obj["closed"] = ["bible", "notes", "highlights", "messages", "agentChat"]
        let l = try JSONDecoder().decode(WorkspaceDockLayout.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertFalse(l.isValid)
        XCTAssertNil(l.repaired())
    }

    // MARK: persistence
    func test_encodeDecode_roundTrip() throws {
        var l = WorkspaceDockLayout.default
        l.move(.notes, to: .centerTop, at: 0)
        l.close(.messages)
        let data = try XCTUnwrap(l.encoded())
        XCTAssertEqual(WorkspaceDockLayout.decode(data), l)
    }

    func test_store_keyIsVersionedAndPerUser() {
        XCTAssertNotEqual(WorkspaceLayoutStore.key(userId: "a"), WorkspaceLayoutStore.key(userId: "b"))
        XCTAssertTrue(WorkspaceLayoutStore.key(userId: "a").contains("v\(WorkspaceDockLayout.schemaVersion)"))
        XCTAssertTrue(WorkspaceLayoutStore.key(userId: "a").hasSuffix(".a"))
        XCTAssertEqual(WorkspaceLayoutStore.key(userId: nil), WorkspaceLayoutStore.key(userId: nil))
    }

    func test_store_saveLoad_roundTrip() {
        let d = freshDefaults()
        var l = WorkspaceDockLayout.default
        l.move(.agentChat, to: .right, at: 1)
        WorkspaceLayoutStore.save(l, defaults: d, userId: "u1")
        XCTAssertEqual(WorkspaceLayoutStore.load(defaults: d, userId: "u1"), l)
    }

    func test_store_perUserIsolation() {
        let d = freshDefaults()
        var a = WorkspaceDockLayout.default
        a.move(.notes, to: .centerTop)
        WorkspaceLayoutStore.save(a, defaults: d, userId: "alice")
        XCTAssertEqual(WorkspaceLayoutStore.load(defaults: d, userId: "alice"), a)
        XCTAssertEqual(WorkspaceLayoutStore.load(defaults: d, userId: "bob"), .default)
        XCTAssertEqual(WorkspaceLayoutStore.load(defaults: d, userId: nil), .default)
    }

    func test_store_emptyDefaults_returnsDefault() {
        XCTAssertEqual(WorkspaceLayoutStore.load(defaults: freshDefaults(), userId: "x"), .default)
    }

    func test_store_garbageBytes_fallBackToDefault() {
        let d = freshDefaults()
        d.set(Data("not json at all {{{".utf8), forKey: WorkspaceLayoutStore.key(userId: "x"))
        XCTAssertEqual(WorkspaceLayoutStore.load(defaults: d, userId: "x"), .default)
    }

    func test_store_wrongTypeStored_fallBackToDefault() {
        let d = freshDefaults()
        d.set("a string, not data", forKey: WorkspaceLayoutStore.key(userId: "x"))
        XCTAssertEqual(WorkspaceLayoutStore.load(defaults: d, userId: "x"), .default)
    }

    func test_store_unknownTabInJSON_fallBackToDefault() throws {
        var obj = try jsonObject(of: .default)
        obj["order"] = ["centerTop": ["bible", "bogusTab"], "centerBottom": ["agentChat"], "right": ["notes", "highlights", "messages"]]
        let d = freshDefaults()
        d.set(try JSONSerialization.data(withJSONObject: obj), forKey: WorkspaceLayoutStore.key(userId: "x"))
        XCTAssertEqual(WorkspaceLayoutStore.load(defaults: d, userId: "x"), .default)
    }

    func test_store_staleVersion_fallBackToDefault() throws {
        var obj = try jsonObject(of: .default)
        obj["version"] = 0
        obj["order"] = ["centerTop": ["notes"], "centerBottom": ["agentChat"], "right": ["bible", "highlights", "messages"]]
        let d = freshDefaults()
        d.set(try JSONSerialization.data(withJSONObject: obj), forKey: WorkspaceLayoutStore.key(userId: "x"))
        XCTAssertEqual(WorkspaceLayoutStore.load(defaults: d, userId: "x"), .default)
    }

    func test_store_futureVersion_fallBackToDefault() throws {
        var obj = try jsonObject(of: .default)
        obj["version"] = WorkspaceDockLayout.schemaVersion + 1
        XCTAssertNil(WorkspaceDockLayout.decode(try JSONSerialization.data(withJSONObject: obj)))
    }

    func test_store_duplicateTabAcrossDocks_fallBackToDefault() throws {
        var obj = try jsonObject(of: .default)
        obj["order"] = ["centerTop": ["bible", "notes"], "centerBottom": ["agentChat"], "right": ["notes", "highlights", "messages"]]
        XCTAssertNil(WorkspaceDockLayout.decode(try JSONSerialization.data(withJSONObject: obj)))
    }

    func test_decode_missingTab_isRepairedIntoClosed() throws {
        var obj = try jsonObject(of: .default)
        obj["order"] = ["centerTop": ["bible"], "centerBottom": ["agentChat"], "right": ["notes", "highlights"]]
        obj["closed"] = [String]()
        let l = try XCTUnwrap(WorkspaceDockLayout.decode(try JSONSerialization.data(withJSONObject: obj)))
        XCTAssertTrue(l.isValid)
        XCTAssertTrue(l.closed.contains(.messages))
        XCTAssertFalse(l.isOpen(.messages))
    }

    func test_decode_staleActiveTab_isRepaired() throws {
        var obj = try jsonObject(of: .default)
        obj["activeByDock"] = ["centerTop": "bible", "centerBottom": "agentChat", "right": "bible"] // bible is not in right
        let l = try XCTUnwrap(WorkspaceDockLayout.decode(try JSONSerialization.data(withJSONObject: obj)))
        XCTAssertTrue(l.isValid)
        XCTAssertEqual(l.activeTab(in: .right), .notes)
    }

    func test_decode_openTabAlsoListedClosed_isDeduped() throws {
        var obj = try jsonObject(of: .default)
        obj["closed"] = ["notes", "notes"]
        let l = try XCTUnwrap(WorkspaceDockLayout.decode(try JSONSerialization.data(withJSONObject: obj)))
        XCTAssertTrue(l.isValid)
        XCTAssertTrue(l.closed.isEmpty)
    }

    func test_decode_missingFields_returnsNil() {
        XCTAssertNil(WorkspaceDockLayout.decode(Data("{\"version\":1}".utf8)))
    }

    // MARK: drop geometry
    private let frames: [WorkspaceDock: CGRect] = [
        .centerTop: CGRect(x: 0, y: 0, width: 600, height: 300),
        .centerBottom: CGRect(x: 0, y: 308, width: 600, height: 300),
        .right: CGRect(x: 608, y: 0, width: 400, height: 608),
    ]

    func test_drop_insideDock() {
        XCTAssertEqual(WorkspaceDropGeometry.targetDock(at: CGPoint(x: 100, y: 100), frames: frames), .centerTop)
        XCTAssertEqual(WorkspaceDropGeometry.targetDock(at: CGPoint(x: 100, y: 500), frames: frames), .centerBottom)
        XCTAssertEqual(WorkspaceDropGeometry.targetDock(at: CGPoint(x: 800, y: 300), frames: frames), .right)
    }

    func test_drop_gapRoutesToNearest() {
        // y 304 is in the 8pt gap between top (ends 300) and bottom (starts 308), nearer-equal; x in gap between center and right
        XCTAssertEqual(WorkspaceDropGeometry.targetDock(at: CGPoint(x: 603, y: 100), frames: frames), .centerTop)
        XCTAssertEqual(WorkspaceDropGeometry.targetDock(at: CGPoint(x: 606, y: 100), frames: frames), .right)
    }

    func test_drop_edgeBandForgivesOvershoot() {
        let p = CGPoint(x: 1008 + WorkspaceLayout.dropEdgeBand - 1, y: 300)
        XCTAssertEqual(WorkspaceDropGeometry.targetDock(at: p, frames: frames), .right)
    }

    func test_drop_farOutside_isNil() {
        XCTAssertNil(WorkspaceDropGeometry.targetDock(at: CGPoint(x: 2000, y: 2000), frames: frames))
        XCTAssertNil(WorkspaceDropGeometry.targetDock(at: CGPoint(x: 0, y: 0), frames: [:]))
    }

    func test_drop_zeroSizedDock_ignored() {
        var f = frames
        f[.right] = .zero
        XCTAssertNil(WorkspaceDropGeometry.targetDock(at: CGPoint(x: 900, y: 300), frames: f))
    }

    func test_drop_collapsedStrip_hasMinimumTarget() {
        let strip: [WorkspaceDock: CGRect] = [.right: CGRect(x: 1000, y: 0, width: 10, height: 600)]
        let half = WorkspaceLayout.collapsedDockStrip / 2
        XCTAssertEqual(WorkspaceDropGeometry.targetDock(at: CGPoint(x: 1005 - half + 2, y: 300), frames: strip), .right)
    }

    func test_insertionIndex_byPillMidpoints() {
        let pills = [CGRect(x: 0, y: 0, width: 80, height: 44), CGRect(x: 88, y: 0, width: 80, height: 44), CGRect(x: 176, y: 0, width: 80, height: 44)]
        XCTAssertEqual(WorkspaceDropGeometry.insertionIndex(at: 10, pillFrames: pills), 0)
        XCTAssertEqual(WorkspaceDropGeometry.insertionIndex(at: 100, pillFrames: pills), 1)
        XCTAssertEqual(WorkspaceDropGeometry.insertionIndex(at: 150, pillFrames: pills), 2)
        XCTAssertEqual(WorkspaceDropGeometry.insertionIndex(at: 999, pillFrames: pills), 3)
        XCTAssertEqual(WorkspaceDropGeometry.insertionIndex(at: 50, pillFrames: []), 0)
    }

    func test_isInStrip() {
        let f = CGRect(x: 0, y: 100, width: 400, height: 400)
        XCTAssertTrue(WorkspaceDropGeometry.isInStrip(CGPoint(x: 10, y: 120), dockFrame: f))
        XCTAssertFalse(WorkspaceDropGeometry.isInStrip(CGPoint(x: 10, y: 400), dockFrame: f))
    }

    // MARK: WorkspaceState integration
    func test_state_move_persistsAcrossInstances_forSameUser() {
        let d = freshDefaults()
        let s = WorkspaceState(defaults: d, userId: "u1")
        XCTAssertTrue(s.move(.notes, to: .centerTop, at: 0))
        let s2 = WorkspaceState(defaults: d, userId: "u1")
        XCTAssertEqual(s2.layout.dock(of: .notes), .centerTop)
        XCTAssertEqual(s2.layout.tabs(in: .centerTop), [.notes, .bible])
    }

    func test_state_otherUserGetsDefault_andSetUserSwapsLayouts() {
        let d = freshDefaults()
        let s = WorkspaceState(defaults: d, userId: "alice")
        s.move(.notes, to: .centerTop)
        s.setUser("bob")
        XCTAssertEqual(s.layout, .default, "bob must not inherit alice's arrangement")
        s.move(.messages, to: .centerBottom)
        s.setUser("alice")
        XCTAssertEqual(s.layout.dock(of: .notes), .centerTop)
        XCTAssertEqual(s.layout.dock(of: .messages), .right)
        s.setUser("bob")
        XCTAssertEqual(s.layout.dock(of: .messages), .centerBottom)
    }

    func test_state_setUser_closesDrawer() {
        let s = WorkspaceState(defaults: freshDefaults(), userId: "a")
        s.drawerOpen = true
        s.setUser("b")
        XCTAssertFalse(s.drawerOpen)
    }

    func test_state_corruptStoredData_startsFromDefault() {
        let d = freshDefaults()
        d.set(Data([0xFF, 0x00, 0x13]), forKey: WorkspaceLayoutStore.key(userId: "z"))
        XCTAssertEqual(WorkspaceState(defaults: d, userId: "z").layout, .default)
    }

    func test_state_close_lastOpenTab_refusedWithNotice() {
        let s = WorkspaceState(defaults: freshDefaults(), userId: "a")
        for t in [WorkspaceTab.bible, .agentChat, .notes, .highlights] { XCTAssertTrue(s.close(t)) }
        XCTAssertNil(s.notice)
        XCTAssertFalse(s.close(.messages))
        XCTAssertNotNil(s.notice)
        XCTAssertTrue(s.layout.isOpen(.messages))
    }

    func test_state_select_closedSideTab_reopensInLastDock_andOpensDrawer() {
        let s = WorkspaceState(defaults: freshDefaults(), userId: "a")
        s.close(.notes)
        s.select(.notes)
        XCTAssertEqual(s.layout.dock(of: .notes), .right)
        XCTAssertTrue(s.drawerOpen)
        XCTAssertEqual(s.activeRail, .notes)
    }

    func test_state_select_centerTab_doesNotOpenDrawer() {
        let s = WorkspaceState(defaults: freshDefaults(), userId: "a")
        s.select(.bible)
        XCTAssertFalse(s.drawerOpen)
    }

    func test_state_moveToRight_expandsCollapsedRight_andOpensDrawerOnlyWhenAsked() {
        let s = WorkspaceState(defaults: freshDefaults(), userId: "a")
        s.collapseRight()
        s.move(.bible, to: .right)
        XCTAssertFalse(s.rightCollapsed)
        XCTAssertFalse(s.drawerOpen)
        s.move(.agentChat, to: .right, opensDrawer: true)
        XCTAssertTrue(s.drawerOpen)
    }

    func test_state_moveCount_incrementsOnlyOnRealChange() {
        let s = WorkspaceState(defaults: freshDefaults(), userId: "a")
        let c0 = s.moveCount
        s.move(.notes, to: .right, at: 0) // no-op
        XCTAssertEqual(s.moveCount, c0)
        s.move(.notes, to: .centerTop)
        XCTAssertEqual(s.moveCount, c0 + 1)
        s.nudge(.notes, by: -1)
        XCTAssertEqual(s.moveCount, c0 + 2)
    }

    func test_state_resetLayout_restoresDefaultDocks() {
        let d = freshDefaults()
        let s = WorkspaceState(defaults: d, userId: "a")
        s.move(.notes, to: .centerTop)
        s.close(.messages)
        s.resetLayout()
        XCTAssertEqual(s.layout, .default)
        XCTAssertEqual(WorkspaceLayoutStore.load(defaults: d, userId: "a"), .default)
    }

    func test_state_closeLastSideTab_closesDrawer() {
        let s = WorkspaceState(defaults: freshDefaults(), userId: "a")
        s.drawerOpen = true
        for t in [WorkspaceTab.notes, .highlights, .messages] { s.close(t) }
        XCTAssertFalse(s.drawerOpen)
    }

    func test_state_rightTabShim_followsActiveSideTab() {
        let s = WorkspaceState(defaults: freshDefaults(), userId: "a")
        s.selectTab(.messages)
        XCTAssertEqual(s.rightTab, .messages)
    }

    // MARK: helpers
    private func jsonObject(of l: WorkspaceDockLayout) throws -> [String: Any] {
        let data = try XCTUnwrap(l.encoded())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
