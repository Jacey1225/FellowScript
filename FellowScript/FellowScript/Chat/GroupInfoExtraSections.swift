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
}

enum GroupInfoExtraSections {
    /// Append-only table. Empty until a feature task registers a section.
    static let registry: [GroupInfoExtraSection] = [
        GroupPublishSection.registration,   // order 10: owner-only Publish to Explorer
        GroupThreadsSection.registration,   // order 30: message threads (flag `threads`)
    ]

    static func visible(_ sections: [GroupInfoExtraSection] = registry,
                        capabilities: FSCapabilities,
                        context: GroupInfoSectionContext) -> [GroupInfoExtraSection] {
        sections
            .sorted { $0.order < $1.order }
            .filter { $0.isVisible(capabilities, context) }
    }
}

struct GroupInfoExtraSectionsView: View {
    @Environment(\.fsCapabilities) private var capabilities
    let context: GroupInfoSectionContext

    var body: some View {
        let sections = GroupInfoExtraSections.visible(capabilities: capabilities, context: context)
        ForEach(sections, id: \.id) { section in
            section.makeView(capabilities, context)
        }
    }
}
