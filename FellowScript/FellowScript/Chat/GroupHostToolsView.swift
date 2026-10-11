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
    @State private var capDraft = ""

    var body: some View {
        if let info = vm.info, info.is_owner {
            let current = info.max_members.map(String.init) ?? ""
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                label("Member limit")
                Text("Most people allowed in this group. Leave blank for no limit.")
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                TextField("No limit", text: $capDraft)
                    .keyboardType(.numberPad)
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.parchment)
                    .padding(.horizontal, Theme.spacingSM)
                    .frame(minHeight: 44)
                    .background(Theme.cardBg)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderGoldDim, lineWidth: 1))
                    .disabled(vm.savingCap)
                    .onChange(of: capDraft) { _, v in
                        let digits = String(v.filter(\.isNumber).prefix(6))
                        if digits != v { capDraft = digits }
                        vm.capError = nil; vm.capSaved = false
                    }
                    .accessibilityLabel("Maximum members")
                if let ceiling = info.max_members_ceiling {
                    Text("Up to \(ceiling). Not lower than the \(info.member_count ?? info.members.count) people here now.")
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                }
                if let err = vm.capError {
                    Text(err).font(.inter(Theme.fontXS)).foregroundColor(Theme.error).accessibilityLabel(err)
                }
                if vm.capSaved {
                    Text("Limit saved.").font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                        .accessibilityLabel("Member limit saved")
                }
                PillButton(title: vm.savingCap ? "Saving…" : "Save limit") {
                    let trimmed = capDraft.trimmingCharacters(in: .whitespaces)
                    Task { _ = await vm.setMaxMembers(trimmed.isEmpty ? nil : Int(trimmed)) }
                }
                .disabled(vm.savingCap || capDraft.trimmingCharacters(in: .whitespaces) == current)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { capDraft = current }
            .onChange(of: current) { _, v in capDraft = v }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.inter(Theme.fontXXS, weight: .semibold)).tracking(3).textCase(.uppercase)
            .foregroundColor(Theme.gold.opacity(0.7))
            .accessibilityAddTraits(.isHeader)
    }
}

struct GroupHostToolsView: View {
    @ObservedObject var vm: GroupInfoViewModel
    let service: DataServiceProtocol
    let context: GroupInfoSectionContext
    var onGroupGone: () -> Void

    @Environment(\.dismiss) private var dismiss

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
                    .font(.inter(Theme.fontXS, weight: .bold)).tracking(3)
                    .foregroundColor(Theme.gold.opacity(0.85))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, Theme.spacingMD)
            .padding(.top, Theme.spacingSM)
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
        }
        .warmBloomBackground()
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
    }
}
