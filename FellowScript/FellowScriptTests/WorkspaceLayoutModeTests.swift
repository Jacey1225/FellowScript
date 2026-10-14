// WorkspaceLayoutModeTests.swift — task 20261013-ipad-adaptive-desktop-mirror.
// Covers size-class mode selection, feature flag, layout math and WorkspaceState.

import XCTest
import SwiftUI
@testable import FellowScript

@MainActor
final class WorkspaceLayoutModeTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "WorkspaceLayoutModeTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: mode selection
    func test_regularWidth_flagOn_isWorkspace() {
        XCTAssertEqual(WorkspaceLayoutMode.resolve(sizeClass: .regular, flagEnabled: true), .workspace)
    }
    func test_compactWidth_flagOn_isPhoneTabs() {
        XCTAssertEqual(WorkspaceLayoutMode.resolve(sizeClass: .compact, flagEnabled: true), .phoneTabs)
    }
    func test_regularWidth_flagOff_isPhoneTabs() {
        XCTAssertEqual(WorkspaceLayoutMode.resolve(sizeClass: .regular, flagEnabled: false), .phoneTabs)
    }
    func test_nilSizeClass_isPhoneTabs() {
        XCTAssertEqual(WorkspaceLayoutMode.resolve(sizeClass: nil, flagEnabled: true), .phoneTabs)
    }
    func test_compactWidth_flagOff_isPhoneTabs() {
        XCTAssertEqual(WorkspaceLayoutMode.resolve(sizeClass: .compact, flagEnabled: false), .phoneTabs)
    }

    // MARK: feature flag
    func test_flag_defaultsOn_whenUnset() {
        XCTAssertTrue(WorkspaceLayout.isFeatureEnabled(freshDefaults()))
    }
    func test_flag_honorsStoredFalseAndTrue() {
        let d = freshDefaults()
        d.set(false, forKey: WorkspaceLayout.featureFlagKey)
        XCTAssertFalse(WorkspaceLayout.isFeatureEnabled(d))
        d.set(true, forKey: WorkspaceLayout.featureFlagKey)
        XCTAssertTrue(WorkspaceLayout.isFeatureEnabled(d))
    }

    // MARK: layout math
    func test_rightPanelWidth_clampsToMinAndMax() {
        XCTAssertEqual(WorkspaceLayout.rightPanelWidth(total: 500, ratio: 0.34), WorkspaceLayout.rightPanelMinWidth)
        XCTAssertEqual(WorkspaceLayout.rightPanelWidth(total: 3000, ratio: 0.34), WorkspaceLayout.rightPanelMaxWidth)
        XCTAssertEqual(WorkspaceLayout.rightPanelWidth(total: 1200, ratio: 0.34), 408, accuracy: 0.001)
    }
    func test_drawerWidth_capsAtMax() {
        XCTAssertEqual(WorkspaceLayout.drawerWidth(total: 1000), 420)
        XCTAssertEqual(WorkspaceLayout.drawerWidth(total: 500), 300, accuracy: 0.001)
    }
    func test_clampBibleSplit() {
        XCTAssertEqual(WorkspaceLayout.clampBibleSplit(0.0), WorkspaceLayout.bibleSplitMin)
        XCTAssertEqual(WorkspaceLayout.clampBibleSplit(1.0), WorkspaceLayout.bibleSplitMax)
        XCTAssertEqual(WorkspaceLayout.clampBibleSplit(0.5), 0.5)
    }
    func test_isLandscape() {
        XCTAssertTrue(WorkspaceLayout.isLandscape(CGSize(width: 1376, height: 1032)))
        XCTAssertFalse(WorkspaceLayout.isLandscape(CGSize(width: 1032, height: 1376)))
        XCTAssertFalse(WorkspaceLayout.isLandscape(CGSize(width: 800, height: 800)))
    }
    func test_roman() {
        XCTAssertEqual(WorkspaceLayout.roman(1), "I")
        XCTAssertEqual(WorkspaceLayout.roman(4), "IV")
        XCTAssertEqual(WorkspaceLayout.roman(9), "IX")
        XCTAssertEqual(WorkspaceLayout.roman(14), "XIV")
        XCTAssertEqual(WorkspaceLayout.roman(119), "CXIX")
        XCTAssertEqual(WorkspaceLayout.roman(150), "CL")
        XCTAssertEqual(WorkspaceLayout.roman(0), "0")
        XCTAssertEqual(WorkspaceLayout.roman(4000), "4000")
    }

    // MARK: rail / tab mapping
    func test_railOrder_matchesDesktop() {
        XCTAssertEqual(WorkspaceRailItem.allCases, [.bible, .notes, .highlights, .messages, .agentChat])
    }
    func test_railRightTabMapping_roundTrips() {
        XCTAssertNil(WorkspaceRailItem.bible.rightTab)
        XCTAssertNil(WorkspaceRailItem.agentChat.rightTab)
        for tab in WorkspaceRightTab.allCases { XCTAssertEqual(tab.railItem.rightTab, tab) }
    }

    // MARK: WorkspaceState
    func test_state_defaults() {
        let s = WorkspaceState(defaults: freshDefaults())
        XCTAssertEqual(s.activeRail, .bible)
        XCTAssertEqual(s.rightTab, .notes)
        XCTAssertFalse(s.rightCollapsed)
        XCTAssertFalse(s.bibleCollapsed)
        XCTAssertFalse(s.agentCollapsed)
        XCTAssertEqual(s.rightRatio, WorkspaceLayout.rightPanelDefaultRatio)
        XCTAssertEqual(s.bibleSplit, WorkspaceLayout.bibleSplitDefault)
        XCTAssertFalse(s.drawerOpen)
    }
    func test_state_selectRightItem_opensTabAndExpands() {
        let s = WorkspaceState(defaults: freshDefaults())
        s.collapseRight()
        s.select(.messages)
        XCTAssertEqual(s.activeRail, .messages)
        XCTAssertEqual(s.rightTab, .messages)
        XCTAssertFalse(s.rightCollapsed)
        XCTAssertTrue(s.drawerOpen)
    }
    func test_state_selectBibleAndAgent_restoreCollapsedPanels() {
        let s = WorkspaceState(defaults: freshDefaults())
        s.bibleCollapsed = true; s.agentCollapsed = true
        s.select(.bible); XCTAssertFalse(s.bibleCollapsed); XCTAssertTrue(s.agentCollapsed)
        s.select(.agentChat); XCTAssertFalse(s.agentCollapsed)
        XCTAssertEqual(s.activeRail, .agentChat)
    }
    func test_state_selectTab_syncsRailAndExpands() {
        let s = WorkspaceState(defaults: freshDefaults())
        s.rightCollapsed = true
        s.selectTab(.highlights)
        XCTAssertEqual(s.activeRail, .highlights)
        XCTAssertEqual(s.rightTab, .highlights)
        XCTAssertFalse(s.rightCollapsed)
    }
    func test_state_collapseRight_closesDrawer() {
        let s = WorkspaceState(defaults: freshDefaults())
        s.select(.notes)
        s.collapseRight()
        XCTAssertTrue(s.rightCollapsed)
        XCTAssertFalse(s.drawerOpen)
    }
    func test_state_persistsAcrossInstances_localOnly() {
        let d = freshDefaults()
        let a = WorkspaceState(defaults: d)
        a.selectTab(.messages); a.agentCollapsed = true; a.rightRatio = 0.4; a.bibleSplit = 0.5
        let b = WorkspaceState(defaults: d)
        XCTAssertEqual(b.rightTab, .messages)
        XCTAssertTrue(b.agentCollapsed)
        XCTAssertEqual(b.rightRatio, 0.4)
        XCTAssertEqual(b.bibleSplit, 0.5)
        XCTAssertFalse(b.drawerOpen, "drawer is transient")
    }
    func test_state_outOfRangeStoredSplit_isClamped() {
        let d = freshDefaults()
        d.set(5.0, forKey: "workspace.bibleSplit")
        XCTAssertEqual(WorkspaceState(defaults: d).bibleSplit, WorkspaceLayout.bibleSplitMax)
    }
    func test_state_resetLayout_restoresDefaults() {
        let s = WorkspaceState(defaults: freshDefaults())
        s.rightCollapsed = true; s.bibleCollapsed = true; s.agentCollapsed = true
        s.rightRatio = 0.5; s.bibleSplit = 0.4
        s.resetLayout()
        XCTAssertFalse(s.rightCollapsed); XCTAssertFalse(s.bibleCollapsed); XCTAssertFalse(s.agentCollapsed)
        XCTAssertEqual(s.rightRatio, WorkspaceLayout.rightPanelDefaultRatio)
        XCTAssertEqual(s.bibleSplit, WorkspaceLayout.bibleSplitDefault)
    }
    func test_state_survivesModeFlip() {
        // Same instance (owned by ContentView) keeps state when resolve() flips modes on rotation/Split View.
        let s = WorkspaceState(defaults: freshDefaults())
        s.selectTab(.highlights)
        _ = WorkspaceLayoutMode.resolve(sizeClass: .compact, flagEnabled: true)
        _ = WorkspaceLayoutMode.resolve(sizeClass: .regular, flagEnabled: true)
        XCTAssertEqual(s.rightTab, .highlights)
    }
}
