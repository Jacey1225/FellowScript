// GroupInfo+JoinRequestsFocus.swift -- join_request push deep link (gap G1 of
// task 20261016-push-notifications-and-ui). The chat opens Group Info with
// `fsFocusJoinRequests` set; for an owner the sheet pushes Host tools, whose
// scroll view then brings the Join requests section to the top. Non-owners
// (or a group where the section is hidden) just stay on Group Info.

import SwiftUI

private struct FSFocusJoinRequestsKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var fsFocusJoinRequests: Bool {
        get { self[FSFocusJoinRequestsKey.self] }
        set { self[FSFocusJoinRequestsKey.self] = newValue }
    }
}

enum GroupInfoJoinRequestsFocus {
    /// Anchor id of the Join requests section (matches its registry id).
    static let sectionId = "join_requests"
}

/// Opens Host tools once the owner flag is known, at most once per sheet.
struct OpenHostToolsForJoinRequests: ViewModifier {
    let isOwner: Bool
    @Binding var showHostTools: Bool
    @Environment(\.fsFocusJoinRequests) private var focus
    @State private var handled = false

    func body(content: Content) -> some View {
        content
            .onAppear { apply() }
            .onChange(of: isOwner) { _, _ in apply() }
    }

    private func apply() {
        guard focus, isOwner, !handled else { return }
        handled = true
        showHostTools = true
    }
}

extension View {
    func opensHostToolsForJoinRequests(isOwner: Bool, showHostTools: Binding<Bool>) -> some View {
        modifier(OpenHostToolsForJoinRequests(isOwner: isOwner, showHostTools: showHostTools))
    }

    /// Scrolls the enclosing ScrollViewReader to the Join requests section
    /// when a join_request push asked for it (after the section has loaded).
    func scrollsToJoinRequestsIfRequested(_ proxy: ScrollViewProxy, focus: Bool) -> some View {
        task {
            guard focus else { return }
            for delay in [350_000_000, 900_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                proxy.scrollTo(GroupInfoJoinRequestsFocus.sectionId, anchor: .top)
            }
        }
    }
}
