// ShareLinkViews.swift — task 20261011-ios-share-notes-highlights.
//
// 1. One share-sheet helper (`.shareSheet(item:)`) used by every Share action
//    (note, verse/highlight, announcement). It presents UIActivityViewController
//    inside a SwiftUI sheet, so there is no root-view-controller presenting and no
//    iPad popover anchor to get wrong.
// 2. The two confirm screens a tapped link opens: friend request (/u/<name>) and
//    request-to-join (/g/<id>). Neither sends anything until the person taps the
//    button, and every failure uses the same generic copy (no enumeration).
// 3. The announcement Share button, which only appears when the group has a
//    published Explorer listing the viewer may link to.

import SwiftUI
import UIKit

// ── Share sheet ──────────────────────────────────────────────────────────────

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension View {
    /// Presents the system share sheet for `item` (the full composed text is what gets sent).
    func shareSheet(item: Binding<SharePayload?>) -> some View {
        sheet(item: item) { payload in
            ActivityShareSheet(text: payload.text)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
    }
}

// ── Shared styling helpers ───────────────────────────────────────────────────

private struct LinkPrimaryButton: View {
    let title: String
    let busy: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().tint(Theme.ink) }
                else { Text(title).font(.system(size: 16, weight: .bold)) }
            }
            .foregroundColor(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Theme.goldGradient)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(busy ? "Sending" : title)
    }
}

private struct LinkTextButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: Theme.fontSM, weight: .semibold)).foregroundColor(Theme.gold)
                .frame(minWidth: 88, minHeight: 44)
        }
    }
}

// ── Friend request confirm (/u/<username>) ───────────────────────────────────

enum FriendLinkLogic {
    /// A link to your own profile is answered with a neutral message, never a request.
    static func isSelf(_ username: String, current: String?) -> Bool {
        guard let current, !current.isEmpty else { return false }
        return username.caseInsensitiveCompare(current) == .orderedSame
    }
}

struct FriendLinkConfirmView: View {
    let username: String
    let onClose: () -> Void

    @EnvironmentObject private var appState: AppState
    private enum Phase: Equatable { case ask, sending, sent, failed(String) }
    @State private var phase: Phase = .ask
    @AccessibilityFocusState private var headingFocused: Bool

    private var isSelf: Bool { FriendLinkLogic.isSelf(username, current: appState.currentUser?.username) }

    var body: some View {
        VStack(spacing: Theme.spacingMD) {
            Spacer(minLength: 0)
            content.frame(maxWidth: 420)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.spacingMD)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .warmBloomBackground()
        .preferredColorScheme(.dark)
        .onAppear { headingFocused = true }
    }

    @ViewBuilder private var content: some View {
        if isSelf {
            VStack(spacing: Theme.spacingMD) {
                heading("That's your own link")
                Text("Share it with a friend so they can send you a request.")
                    .font(.system(size: Theme.fontSM)).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center)
                LinkPrimaryButton(title: "Done", busy: false, action: onClose)
            }
        } else {
            switch phase {
            case .ask, .sending, .failed:
                VStack(spacing: Theme.spacingMD) {
                    heading("Send a friend request to \(username)?")
                    if case .failed(let msg) = phase {
                        Text(msg).font(.system(size: Theme.fontSM)).foregroundColor(Theme.error).multilineTextAlignment(.center)
                    } else {
                        Text("They get a request and choose whether to accept.")
                            .font(.system(size: Theme.fontSM)).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center)
                    }
                    LinkPrimaryButton(title: "Send request", busy: phase == .sending) { Task { await send() } }
                    LinkTextButton(title: "Cancel", action: onClose).disabled(phase == .sending)
                }
            case .sent:
                VStack(spacing: Theme.spacingMD) {
                    heading("Request sent")
                    Text("You will be friends once they accept.")
                        .font(.system(size: Theme.fontSM)).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center)
                    LinkPrimaryButton(title: "Done", busy: false, action: onClose)
                }
            }
        }
    }

    private func heading(_ s: String) -> some View {
        Text(s).font(.system(size: Theme.fontDisplayMD, weight: .heavy)).foregroundColor(Theme.parchment)
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($headingFocused)
    }

    private func send() async {
        guard phase != .sending, let uid = appState.currentUser?.user_id else { return }
        phase = .sending
        do {
            try await appState.service.sendFriendRequest(userId: uid, username: username)
            phase = .sent
        } catch AppError.rateLimited {
            phase = .failed("Too many tries. Wait a moment and try again.")
        } catch {
            // Same copy for unknown / blocked / anything else: no account enumeration.
            phase = .failed("Couldn't send that request.")
        }
    }
}

// ── Request to join confirm (/g/<public_id>) ─────────────────────────────────

struct GroupLinkRequestView: View {
    let publicId: String
    let onClose: () -> Void

    @EnvironmentObject private var appState: AppState
    private enum Phase: Equatable {
        case loading, ready(FSListingPreview), unavailable, sending(FSListingPreview)
        case sent, alreadyMember, failed(FSListingPreview, String)
    }
    @State private var phase: Phase = .loading
    @AccessibilityFocusState private var headingFocused: Bool

    private var service: ShareLinkService? { appState.service as? ShareLinkService }
    /// Request to join needs both flags for this user; either off is the neutral message.
    private var available: Bool {
        appState.capabilities.isEnabled("explorer_browse") && appState.capabilities.isEnabled("join_requests")
    }

    var body: some View {
        VStack(spacing: Theme.spacingMD) {
            Spacer(minLength: 0)
            content.frame(maxWidth: 420)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.spacingMD)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .warmBloomBackground()
        .preferredColorScheme(.dark)
        .task { await load() }
        .onChange(of: phase) { _, _ in headingFocused = true }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: Theme.spacingSM) {
                ProgressView().tint(Theme.gold)
                Text("Checking this link...").font(.system(size: Theme.fontXS)).foregroundColor(Theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
        case .unavailable:
            VStack(spacing: Theme.spacingMD) {
                heading("This group isn't available right now")
                Text("The link may be out of date, or the group isn't taking requests.")
                    .font(.system(size: Theme.fontSM)).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center)
                LinkPrimaryButton(title: "Back to FellowScript", busy: false, action: onClose)
            }
        case .ready(let p), .sending(let p), .failed(let p, _):
            VStack(spacing: Theme.spacingMD) {
                // Title comes from the server response, rendered as plain Text.
                heading(p.title)
                VStack(spacing: 2) {
                    if let church = p.churchName, !church.isEmpty { Text(church) }
                    if let place = p.locationLine { Text(place) }
                }
                .font(.system(size: Theme.fontSM)).foregroundColor(Theme.textSecondary)
                if let s = p.summary, !s.isEmpty {
                    Text(s).font(.system(size: Theme.fontSM)).foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center).lineLimit(6)
                }
                if case .failed(_, let msg) = phase {
                    Text(msg).font(.system(size: Theme.fontSM)).foregroundColor(Theme.error).multilineTextAlignment(.center)
                } else {
                    Text("The host approves each request before anyone joins.")
                        .font(.system(size: Theme.fontXS)).foregroundColor(Theme.textMuted).multilineTextAlignment(.center)
                }
                LinkPrimaryButton(title: "Request to join", busy: isSending) { Task { await send(p) } }
                LinkTextButton(title: "Cancel", action: onClose).disabled(isSending)
            }
        case .sent:
            VStack(spacing: Theme.spacingMD) {
                heading("Request sent")
                Text("The host has to approve it before you can join.")
                    .font(.system(size: Theme.fontSM)).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center)
                LinkPrimaryButton(title: "Done", busy: false, action: onClose)
            }
        case .alreadyMember:
            VStack(spacing: Theme.spacingMD) {
                heading("You're already in this group")
                LinkPrimaryButton(title: "Done", busy: false, action: onClose)
            }
        }
    }

    private var isSending: Bool { if case .sending = phase { return true } else { return false } }

    private func heading(_ s: String) -> some View {
        Text(s).font(.system(size: Theme.fontDisplayMD, weight: .heavy)).foregroundColor(Theme.parchment)
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($headingFocused)
    }

    /// Read-only fetch; nothing is requested here. Flag off / unsupported service /
    /// not requestable all land on the same neutral state, with no join call made.
    private func load() async {
        guard AppLink.isValidPublicId(publicId), available, let service else { phase = .unavailable; return }
        do {
            let p = try await service.fetchListingPreview(publicId: publicId)
            phase = p.requestable ? .ready(p) : .unavailable
        } catch FSShareLinkError.unavailable {
            phase = .unavailable
        } catch {
            phase = .unavailable
        }
    }

    private func send(_ p: FSListingPreview) async {
        guard !isSending, let uid = appState.currentUser?.user_id, let service else { return }
        phase = .sending(p)
        do {
            switch try await service.requestToJoinListing(userId: uid, publicId: publicId) {
            case .requested: phase = .sent
            case .alreadyMember: phase = .alreadyMember
            }
        } catch FSShareLinkError.unavailable {
            phase = .unavailable
        } catch FSShareLinkError.rateLimited {
            phase = .failed(p, "Too many tries. Wait a moment and try again.")
        } catch {
            phase = .failed(p, "Couldn't send that request. Try again.")
        }
    }
}

// ── Announcement share ───────────────────────────────────────────────────────

enum AnnouncementShare {
    /// The composed share text, or nil (Share hidden). Non-nil only when the
    /// announcement is published AND the group has a published Explorer listing this
    /// member may link to (server answers a generic 404 otherwise) AND the group name
    /// resolved. Any failure means no Share (fail closed); the listing id lives only
    /// in the returned text and is never stored or logged.
    @MainActor
    static func payload(for item: FSGroupAnnouncement, appState: AppState) async -> SharePayload? {
        guard item.published, appState.capabilities.isEnabled("explorer_browse"),
              let uid = appState.currentUser?.user_id,
              let service = appState.service as? ShareLinkService else { return nil }
        do {
            guard let publicId = try await service.fetchGroupShareLinkPublicId(userId: uid, groupId: item.group_id) else { return nil }
            let info = try await appState.service.fetchGroupInfo(userId: uid, groupId: item.group_id)
            return SharePayloads.announcement(groupName: info.title, title: item.title,
                                              publishAt: item.publish_at, published: item.published,
                                              publicId: publicId)
        } catch {
            return nil
        }
    }
}
