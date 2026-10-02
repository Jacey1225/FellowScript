// GroupPublishSection.swift — owner-only "Publish to Explorer" row for the
// GroupInfoSheet registry (order 10; task 20261001-ios-explorer-entry step 2).
// Visible only when explorer_publish is on for the caller, the caller owns the
// group, and links.explore is a valid https URL. Opens
// /#/explore/manage?group=<id> in the in-app Safari sheet. No analytics.

import SwiftUI

/// Secondary-line copy variants keyed to decision J13 (Apple-only accounts).
/// J13 is undecided, so `current` is the honest (c) wording: it states the
/// limitation. Switch `current` when J13 is recorded; layout is unchanged.
enum PublishRowCopy: Equatable {
    case signInInBrowser      // (a) web Sign in with Apple live
    case appleOnlyLimitation  // (c) accepted dead end (interim default)
    case resetPasswordFirst   // (d) password reset path

    static let current: PublishRowCopy = .appleOnlyLimitation

    var secondaryLine: String {
        switch self {
        case .signInInBrowser:
            return "You will sign in in your browser."
        case .appleOnlyLimitation:
            return "You will sign in in your browser. Accounts created with Apple only can't sign in on the website yet."
        case .resetPasswordFirst:
            return "You will sign in in your browser. Signed up with Apple? Set a password first from the sign-in page."
        }
    }
}

struct GroupPublishSection: View {
    let capabilities: FSCapabilities
    let context: GroupInfoSectionContext
    @State private var destination: ExploreDestination?

    var body: some View {
        Button {
            if let url = ExploreEntry.publishURL(from: capabilities, groupId: context.groupId) {
                destination = ExploreDestination(url: url)
            }
        } label: {
            HStack(spacing: Theme.spacingSM) {
                Image(systemName: "square.and.arrow.up").foregroundColor(Theme.gold)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Publish to Explorer").font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                    Text(PublishRowCopy.current.secondaryLine)
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(Theme.spacingSM)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Publish to Explorer")
        .accessibilityValue(PublishRowCopy.current.secondaryLine)
        .accessibilityHint("Opens your browser view to manage this group's listing")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("publish-to-explorer-row")
        .exploreSafariSheet($destination)
    }

    static let registration = GroupInfoExtraSection(
        id: "publish",
        order: 10,
        isVisible: { caps, ctx in
            ExploreEntry.showsPublishRow(caps, isOwner: ctx.isOwner, groupId: ctx.groupId)
        },
        makeView: { caps, ctx in AnyView(GroupPublishSection(capabilities: caps, context: ctx)) }
    )
}
