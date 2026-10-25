// GroupInfoStates.swift -- task 20261023-group-info-row. Loading, empty, error
// and failed-refresh views shared by the four submenu lists.

import SwiftUI

struct GroupInfoLoadingView: View {
    let category: GroupInfoCategory
    var body: some View {
        ProgressView().tint(Theme.gold)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Loading \(category.errorNoun)")
    }
}

struct GroupInfoEmptyView: View {
    let category: GroupInfoCategory
    var body: some View {
        let copy = GroupInfoCopy.empty(category)
        VStack(spacing: 6) {
            Text(copy.title)
                .font(.inter(Theme.fontBody, weight: .bold))
            Text(copy.hint)
                .font(.inter(Theme.fontSM))
                .multilineTextAlignment(.center)
        }
        .foregroundColor(Theme.parchment.opacity(0.6))
        .padding(Theme.spacingLG)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct GroupInfoErrorView: View {
    let category: GroupInfoCategory
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            Text(GroupInfoCopy.loadError(category))
                .font(.inter(Theme.fontBody))
                .foregroundColor(Theme.parchment.opacity(0.6))
                .multilineTextAlignment(.center)
            Button(GroupInfoCopy.tryAgain, action: retry)
                .font(.inter(Theme.fontBody, weight: .bold))
                .foregroundColor(Theme.gold)
                .frame(minHeight: 44)
        }
        .padding(Theme.spacingLG)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One muted line pinned above a still-shown cached list.
struct GroupInfoRefreshNote: View {
    let retry: () -> Void
    var body: some View {
        HStack {
            Text(GroupInfoCopy.refreshNote)
                .font(.inter(Theme.fontXS))
                .foregroundColor(Theme.parchment.opacity(0.6))
            Spacer(minLength: 8)
            Button(GroupInfoCopy.tryAgain, action: retry)
                .font(.inter(Theme.fontXS, weight: .semibold))
                .foregroundColor(Theme.gold)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, Theme.spacingMD)
    }
}
