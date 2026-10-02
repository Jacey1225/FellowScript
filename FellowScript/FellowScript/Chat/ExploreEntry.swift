// ExploreEntry.swift — iOS entry to the website Explore page (task
// 20261001-ios-explorer-entry step 2). Pure URL/visibility logic, the Groups
// "Explore groups" row, and the in-app Safari sheet wrapper.
//
// Visibility and URL come only from GET /app/capabilities (FSCapabilities):
// hidden on any non-200, decode failure, flag off, missing link, non-https
// link or a host that is not the app's own API host (fail closed). No
// analytics, no URL logging, no new auth handoff.

import SwiftUI
import SafariServices

// ── Pure logic (unit-testable) ───────────────────────────────────────────────

enum ExploreEntry {

    /// Host of the app's own site, derived from the existing API base so no
    /// deploy-specific value is hardcoded here.
    static var defaultHost: String? { URL(string: NetworkService.shared.apiBase)?.host?.lowercased() }

    /// The Explore URL to open, or nil when the entry must be hidden.
    static func browseURL(from caps: FSCapabilities, expectedHost: String? = defaultHost) -> URL? {
        guard caps.isEnabled("explorer_browse"),
              let raw = caps.exploreLink,
              let url = validated(raw, expectedHost: expectedHost) else { return nil }
        return url
    }

    /// https only, host must equal the expected host, no credentials.
    static func validated(_ raw: String, expectedHost: String?) -> URL? {
        guard let expectedHost, !expectedHost.isEmpty,
              let comps = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme?.lowercased() == "https",
              comps.user == nil, comps.password == nil,
              comps.host?.lowercased() == expectedHost,
              let url = comps.url else { return nil }
        return url
    }

    /// Owner "Publish to Explorer" destination:
    /// `<origin of links.explore>/#/explore/manage?group=<id>`; nil when
    /// explorer_publish is off, the link is unusable, or the id is empty.
    static func publishURL(from caps: FSCapabilities, groupId: String,
                           expectedHost: String? = defaultHost) -> URL? {
        guard caps.isEnabled("explorer_publish"),
              !groupId.isEmpty,
              let base = browseURL(from: caps, expectedHost: expectedHost),
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?%/")
        guard let enc = groupId.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        comps.path = ""
        comps.query = nil
        comps.percentEncodedFragment = "/explore/manage?group=\(enc)"
        return comps.url
    }

    /// Owner row visibility matrix.
    static func showsPublishRow(_ caps: FSCapabilities, isOwner: Bool, groupId: String,
                                expectedHost: String? = defaultHost) -> Bool {
        isOwner && publishURL(from: caps, groupId: groupId, expectedHost: expectedHost) != nil
    }
}

// ── Safari sheet ─────────────────────────────────────────────────────────────

struct ExploreDestination: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}

struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: config)
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

extension View {
    /// Presents `destination` in an in-app Safari sheet (Done returns to the caller).
    func exploreSafariSheet(_ destination: Binding<ExploreDestination?>) -> some View {
        sheet(item: destination) { dest in
            SafariSheet(url: dest.url).ignoresSafeArea()
        }
    }
}

// ── Groups-segment row ───────────────────────────────────────────────────────

/// Press feedback: gentle scale plus fill change; scale is dropped under Reduce Motion.
private struct ExploreRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(Theme.parchment.opacity(configuration.isPressed ? 0.12 : 0.06)))
            .overlay(Capsule().stroke(Theme.parchment.opacity(0.12), lineWidth: 1))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ExploreEntryRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.spacingSM) {
                Image(systemName: "safari")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.gold)
                    .accessibilityHidden(true)
                Text("Explore groups")
                    .font(.inter(Theme.fontSM).weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: Theme.spacingXS)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Capsule())
        }
        .buttonStyle(ExploreRowButtonStyle())
        .accessibilityLabel("Explore groups")
        .accessibilityHint("Opens the community Explore page in a browser view")
        .accessibilityIdentifier("explore-groups-row")
    }
}
