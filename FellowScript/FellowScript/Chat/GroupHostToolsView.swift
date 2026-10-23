// GroupHostToolsView.swift — owner-only "Host tools" sub page pushed from
// Group Info. Hosts the existing invite link, member limit, join requests and
// Explorer publish sections unchanged; registry sections with placement
// `.hostTools` render here through the same fail-closed visibility filter.

import SwiftUI

enum GroupHostTools {
    /// Entry row shows for the owner only. The member limit editor is always
    /// available to an owner, so that item alone keeps the row visible; the
    /// registry host-tool sections are counted too so the rule stays explicit.
    static func showsEntryRow(isOwner: Bool,
                              capabilities: FSCapabilities,
                              context: GroupInfoSectionContext,
                              sections: [GroupInfoExtraSection] = GroupInfoExtraSections.registry) -> Bool {
        guard isOwner else { return false }
        let hostSections = GroupInfoExtraSections.visible(
            sections, placement: .hostTools, capabilities: capabilities, context: context)
        return hasMemberLimitItem(isOwner: isOwner) || !hostSections.isEmpty
    }

    static func hasMemberLimitItem(isOwner: Bool) -> Bool { isOwner }
}

/// Owner member-limit editor, extracted from GroupInfoSheet (behavior identical).
struct GroupMemberLimitEditor: View {
    @ObservedObject var vm: GroupInfoViewModel
    @State private var limitOn = false
    @State private var capValue = 50

    var body: some View {
        if let info = vm.info, info.is_owner {
            let current = info.max_members
            let ceiling = info.max_members_ceiling ?? 999_999
            let floor = max(1, info.member_count ?? info.members.count)
            FSFormCard(title: "Member limit") {
                FSToggleRow(title: "Limit members",
                            helper: "Most people allowed in this group. Turn off for no limit.",
                            isOn: $limitOn, disabled: vm.savingCap)
                    .onChange(of: limitOn) { _, _ in vm.capError = nil; vm.capSaved = false }
                if limitOn {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Max members").font(.fsLabel).foregroundColor(Theme.textPrimary)
                        FSNumberStepper(value: $capValue, range: floor...max(floor, ceiling), unit: "members")
                            .onChange(of: capValue) { _, _ in vm.capError = nil; vm.capSaved = false }
                            .accessibilityLabel("Maximum members")
                        if info.max_members_ceiling != nil {
                            Text("Up to \(ceiling). Not lower than the \(floor) people here now.")
                                .font(.fsHelper).foregroundColor(Theme.textSecondary)
                        }
                    }
                }
                if let err = vm.capError {
                    FSInlineError(message: err)
                }
                if vm.capSaved {
                    Text("Limit saved.").font(.fsHelper).foregroundColor(Theme.textSecondary)
                        .accessibilityLabel("Member limit saved")
                }
                PillButton(title: vm.savingCap ? "Saving…" : "Save limit") {
                    Task { _ = await vm.setMaxMembers(limitOn ? capValue : nil) }
                }
                .disabled(vm.savingCap || (limitOn ? capValue == current : current == nil))
            }
            .onAppear { sync(current) }
            .onChange(of: current) { _, v in sync(v) }
        }
    }

    private func sync(_ current: Int?) {
        limitOn = current != nil
        capValue = current ?? 50
    }
}

struct GroupHostToolsView: View {
    @ObservedObject var vm: GroupInfoViewModel
    let service: DataServiceProtocol
    let context: GroupInfoSectionContext
    var onGroupGone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.fsFocusJoinRequests) private var focusJoinRequests

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.gold)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Back to group info")
                Text("HOST TOOLS")
                    .font(.system(size: Theme.fontXS, weight: .bold)).tracking(3)
                    .foregroundColor(Theme.gold.opacity(0.85))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, Theme.spacingMD)
            .padding(.top, Theme.spacingSM)
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingLG) {
                    InviteLinkSection(
                        service: service, groupId: context.groupId, userId: context.userId,
                        onGroupGone: onGroupGone)
                    GroupMemberLimitEditor(vm: vm)
                    GroupInfoExtraSectionsView(context: context, placement: .hostTools)
                }
                .padding(.horizontal, Theme.spacingMD)
                .padding(.bottom, Theme.spacingXL)
            }
            .scrollsToJoinRequestsIfRequested(proxy, focus: focusJoinRequests)
            }
        }
        .warmBloomBackground()
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
    }
}
