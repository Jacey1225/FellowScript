// IPadBadgeWiringTests.swift -- testing gate for task
// 20261016-ipad-parity-and-persistent-badges.
//
// Source-pinned wiring checks for the iPad workspace shell (WorkspaceView: left
// rail + header, no FloatingTabBar) and the shared badge surfaces. A SwiftUI
// WorkspaceView cannot be introspected from a unit test, so these pin the exact
// seams a regression would remove; the real rendering is covered by the iPad
// screenshot UI test. Plus pure checks of the shared label helpers and the
// shell selection (regular width => workspace, compact => phone tabs).

import XCTest
import SwiftUI
@testable import FellowScript

@MainActor
final class IPadBadgeWiringTests: XCTestCase {

    private func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("FellowScript/\(rel)"), encoding: .utf8)
    }

    // MARK: WorkspaceView rail + header badges

    func test_workspaceRail_messagesItemShowsCombinedChatBadge() throws {
        let src = try source("Workspace/WorkspaceView.swift")
        XCTAssertTrue(src.contains("item == .messages"), "badge only on the Messages rail item")
        XCTAssertTrue(src.contains("appState.badges.chatBadgeCount(unreadConversations: appState.unreadConversationCount)"),
                      "same value as the phone Chat tab (unread conversations + join-request groups)")
        XCTAssertTrue(src.contains("NavCountBadge(count: badge, ring: Theme.bgPage)"))
        XCTAssertTrue(src.contains(".accessibilityLabel(railAccessibilityLabel(item))"),
                      "rail VoiceOver label must carry the counts")
        XCTAssertTrue(src.contains("BadgeCountsStore.chatAccessibilitySummary("))
    }

    func test_workspaceHeader_avatarAndMenuShowFriendRequestBadge() throws {
        let src = try source("Workspace/WorkspaceView.swift")
        XCTAssertTrue(src.contains("appState.badges.pendingFriendRequestCount"))
        XCTAssertTrue(src.contains("NavCountBadge(count: friendRequestCount, ring: Theme.bgPage)"))
        XCTAssertTrue(src.contains(#"Account (\(friendRequestCount > 9 ? "9+" : "\(friendRequestCount)"))"#),
                      "Account menu item title carries the count, 9+ capped")
        XCTAssertTrue(src.contains("BadgeCountsStore.friendRequestAccessibilitySummary(friendRequestCount)"))
        XCTAssertTrue(src.contains(#""Account menu, \($0)""#))
    }

    func test_workspace_noOtherRailItemCarriesABadge() throws {
        let src = try source("Workspace/WorkspaceView.swift")
        XCTAssertTrue(src.contains("unreadConversations: appState.unreadConversationCount)\n            : 0"), "railBadgeCount returns 0 for every non-Messages item")
    }

    // MARK: Friend-request push routing parity

    func test_workspace_friendRequestPush_opensAccountSheet_warmAndColdStart() throws {
        let src = try source("Workspace/WorkspaceView.swift")
        XCTAssertTrue(src.contains(".onChange(of: appState.pendingFriendRequestsOpen) { _, wanted in\n            if wanted, !showAccount { showAccount = true }"),
                      "warm tap opens the Account sheet and never re-presents an open one")
        XCTAssertTrue(src.contains(".onAppear { if appState.pendingFriendRequestsOpen, !showAccount { showAccount = true } }"),
                      "cold start: flag set before the view existed")
        // The phone shell does the same for its tab; both must keep doing it.
        let phone = try source("ContentView.swift")
        XCTAssertTrue(phone.contains("if wanted { selectedTab = .account }"))
        XCTAssertTrue(phone.contains("if appState.pendingFriendRequestsOpen { selectedTab = .account }"))
    }

    func test_chatLikePushes_stillRouteToMessagesOnIPad() throws {
        let src = try source("Workspace/WorkspaceView.swift")
        XCTAssertTrue(src.contains(".onChange(of: appState.pendingChatContact) { _, t in if t != nil { state.select(.messages) } }"))
    }

    func test_accountView_consumesTheFriendRequestFlag() throws {
        let acct = try source("Account/AccountView.swift")
        XCTAssertTrue(acct.contains("pendingFriendRequestsOpen"))
        let misc = try source("Account/AccountView+Misc.swift")
        XCTAssertTrue(misc.contains("appState.pendingFriendRequestsOpen = false"))
    }

    // MARK: Shared surfaces (phone + iPad read the same store)

    func test_floatingTabBar_andWorkspace_shareOneBadgeView() throws {
        let tab = try source("Dashboard/FloatingTabBar.swift")
        let ws = try source("Workspace/WorkspaceView.swift")
        XCTAssertTrue(tab.contains("NavCountBadge(count: count)"))
        XCTAssertTrue(ws.contains("NavCountBadge("))
        let badge = try source("Dashboard/NavCountBadge.swift")
        XCTAssertTrue(badge.contains(#"count > 9 ? "9+""#))
        XCTAssertTrue(badge.contains("Theme.error"))
        XCTAssertTrue(badge.contains(".unreadBadge(reduceMotion: reduceMotion)"))
        XCTAssertTrue(badge.contains(".accessibilityHidden(true)"))
        XCTAssertTrue(badge.contains("withMotionAwareAnimation"), "pulse respects Reduce Motion")
    }

    func test_screens_reportSeenEventsThroughTheStore() throws {
        let acct = try source("Account/AccountView.swift")
        XCTAssertTrue(acct.contains("FriendRequestBadgeSync(ids: vm.friendRequests.map(\\.id), loaded: vm.friendRequestsLoaded)"))
        let joins = try source("Chat/GroupJoinRequestsSection.swift")
        XCTAssertTrue(joins.contains("newestRequestAt: vm.requests.compactMap(\\.createdAt).max()"))
        let dot = try source("Chat/JoinRequestRowDot.swift")
        XCTAssertTrue(dot.contains("guard visible, loaded else { return }"), "friend seen needs screen visible AND list loaded")
        XCTAssertTrue(dot.contains("guard loaded else { return }"), "join seen needs a loaded list")
    }

    func test_appState_hydratesAtLaunchAndSignIn_andWipesOnSignOut() throws {
        let app = try source("Services/AppState.swift")
        XCTAssertTrue(app.contains("if isAuthenticated, let uid = currentUser?.user_id { badges.hydrate(userId: uid) }"))
        XCTAssertTrue(app.contains("badges.hydrate(userId: user.user_id)"))
        XCTAssertTrue(app.contains("badges.clear(forUserId: signedOutUserId)"))
    }

    func test_notificationSettings_contentIsCappedForWideSheets() throws {
        let src = try source("Account/NotificationSettingsView.swift")
        XCTAssertTrue(src.contains(".frame(maxWidth: 560)"))
        XCTAssertTrue(src.contains(".frame(maxWidth: .infinity)"))
    }

    // MARK: Shell selection / labels

    func test_shellSelection_regularWidthIsWorkspace_compactIsPhoneTabs() {
        XCTAssertEqual(WorkspaceLayoutMode.resolve(sizeClass: .regular, flagEnabled: true), .workspace)
        XCTAssertEqual(WorkspaceLayoutMode.resolve(sizeClass: .compact, flagEnabled: true), .phoneTabs,
                       "iPad Split View / Slide Over keeps FloatingTabBar")
        XCTAssertEqual(WorkspaceLayoutMode.resolve(sizeClass: .regular, flagEnabled: false), .phoneTabs)
        XCTAssertEqual(WorkspaceLayoutMode.resolve(sizeClass: nil, flagEnabled: true), .phoneTabs)
    }

    func test_accessibilitySummaries_matchBetweenShells() {
        XCTAssertEqual(BadgeCountsStore.chatAccessibilitySummary(unreadConversations: 3, joinRequestGroups: 1),
                       "3 unread conversations, 1 join request")
        XCTAssertEqual(BadgeCountsStore.chatAccessibilitySummary(unreadConversations: 1, joinRequestGroups: 2),
                       "1 unread conversation, 2 groups with join requests")
        XCTAssertNil(BadgeCountsStore.chatAccessibilitySummary(unreadConversations: 0, joinRequestGroups: 0))
        XCTAssertEqual(BadgeCountsStore.friendRequestAccessibilitySummary(1), "1 friend request")
        XCTAssertEqual(BadgeCountsStore.friendRequestAccessibilitySummary(4), "4 friend requests")
        XCTAssertNil(BadgeCountsStore.friendRequestAccessibilitySummary(0))
    }
}
