// GroupInfoExtraSections.swift — data registry for extra GroupInfoSheet
// sections (task 20261002-shared-foundation step 8). Rendered once between
// "Member limit" and "Members". Later tasks only append an entry to `registry`
// (and add their own section file); GroupInfoSheet.swift is not edited again.
//
// Reserved orders (shared-contract-v2): publish 10, join_requests 20, threads 30.
// An empty registry renders nothing.

import SwiftUI

/// Capabilities flow to any view (including sheets) via the environment so
/// the sheet needs no extra init parameter. Default is the fail-closed all-off.
private struct FSCapabilitiesKey: EnvironmentKey {
    static let defaultValue: FSCapabilities = .allOff
}
extension EnvironmentValues {
    var fsCapabilities: FSCapabilities {
        get { self[FSCapabilitiesKey.self] }
        set { self[FSCapabilitiesKey.self] = newValue }
    }
}

struct GroupInfoSectionContext {
    let service: DataServiceProtocol
    let groupId: String
    let userId: String
    let isOwner: Bool
}

struct GroupInfoExtraSection {
    let id: String
    let order: Int
    let isVisible: (FSCapabilities, GroupInfoSectionContext) -> Bool
    let makeView: (FSCapabilities, GroupInfoSectionContext) -> AnyView
    /// Where the section renders. Host-management sections live on the owner's
    /// "Host tools" sub page instead of the main Group Info list.
    var placement: Placement = .main

    enum Placement { case main, hostTools }
}

enum GroupInfoExtraSections {
    /// Append-only table. Empty until a feature task registers a section.
    static let registry: [GroupInfoExtraSection] = [
        GroupPublishSection.registration,   // order 10: owner-only Publish to Explorer
        GroupJoinRequestsSection.registration, // order 20: owner join requests (flag `join_requests`)
        GroupThreadsSection.registration,   // order 30: message threads (flag `threads`)
    ]

    static func visible(_ sections: [GroupInfoExtraSection] = registry,
                        capabilities: FSCapabilities,
                        context: GroupInfoSectionContext) -> [GroupInfoExtraSection] {
        sections
            .sorted { $0.order < $1.order }
            .filter { $0.isVisible(capabilities, context) }
    }

    /// Visible sections for one placement (same fail-closed gating).
    static func visible(_ sections: [GroupInfoExtraSection] = registry,
                        placement: GroupInfoExtraSection.Placement,
                        capabilities: FSCapabilities,
                        context: GroupInfoSectionContext) -> [GroupInfoExtraSection] {
        visible(sections.filter { $0.placement == placement },
                capabilities: capabilities, context: context)
    }
}

struct GroupInfoExtraSectionsView: View {
    @Environment(\.fsCapabilities) private var capabilities
    let context: GroupInfoSectionContext
    var placement: GroupInfoExtraSection.Placement = .main

    var body: some View {
        let sections = GroupInfoExtraSections.visible(placement: placement, capabilities: capabilities, context: context)
        ForEach(sections, id: \.id) { section in
            section.makeView(capabilities, context)
        }
    }
}
