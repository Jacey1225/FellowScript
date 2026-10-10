// Pure, SDK-free state for the redesigned session call screen
// (task 20261009-session-ui-redesign, design-notes.md). Everything here is a
// plain value type or a tiny observable so it can be unit tested without the
// Amazon Chime SDK, SwiftUI hosting, or a simulator camera.

import SwiftUI
import Foundation
import Combine

// MARK: - Layout selection (design-notes.md §1)

enum CallLayoutMode: Equatable {
    /// No added content: the scattered bubble field.
    case field
    /// Added content (prompts and/or a screen share): all bubbles in one top row.
    case row
}

enum CallContentKind: Equatable {
    case none
    case prompts
    case share
}

enum CallLayoutState {
    /// `row` iff the prompts panel is open or a content-share tile exists.
    static func mode(promptsOpen: Bool, contentShareTileId: Int?) -> CallLayoutMode {
        (promptsOpen || contentShareTileId != nil) ? .row : .field
    }

    /// When both could show, the share takes the content area and the prompts
    /// panel returns when the share stops (promptsOpen is preserved).
    static func contentKind(promptsOpen: Bool, contentShareTileId: Int?) -> CallContentKind {
        if contentShareTileId != nil { return .share }
        return promptsOpen ? .prompts : .none
    }
}

// MARK: - Interactions submenu state (design-notes.md §2)

struct CallInteractionsState: Equatable {
    var isExpanded = false
    var promptsOpen = false

    mutating func toggleExpanded() { isExpanded.toggle() }
    mutating func collapse() { isExpanded = false }

    /// Mute / Camera keep the menu open so they stay quick to flip.
    mutating func didTapToggleItem() { /* intentionally leaves isExpanded alone */ }

    /// Prompts closes the menu and flips the panel.
    mutating func didTapPrompts() {
        promptsOpen.toggle()
        isExpanded = false
    }

    /// Share and Ring close the menu.
    mutating func didTapActionItem() { isExpanded = false }

    mutating func closePrompts() { promptsOpen = false }
}

// MARK: - Prompts source (reads the session's existing prompts, local-only)

enum CallPromptsSource {
    static func prompts(from session: FSSession?) -> [String] {
        (session?.prompts ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

// MARK: - Screen share feature flag (seeded OFF server-side)

enum ScreenShareFlag {
    static let flagName = "screen_share_enabled"
    /// The sending path (ReplayKit broadcast extension -> App Group socket ->
    /// Chime content share) is code-complete as of step 5. It stays dark in
    /// production because the server flag `screen_share_enabled` is seeded OFF;
    /// this constant only says the client code exists.
    static let sendingImplemented = true
    /// Fail-closed: absent / false / unknown means hidden.
    static func isEnabled(_ capabilities: FSCapabilities) -> Bool {
        capabilities.isEnabled(flagName)
    }
}

// MARK: - Content share (receive side) bookkeeping

/// Chime represents a content share as an extra attendee `<attendeeId>#content`
/// with its own video tile (`isContent == true`).
enum ContentShareAttendee {
    static let suffix = "#content"
    static func isContent(_ attendeeId: String) -> Bool { attendeeId.hasSuffix(suffix) }
    static func baseAttendeeId(_ attendeeId: String) -> String {
        isContent(attendeeId) ? String(attendeeId.dropLast(suffix.count)) : attendeeId
    }
}

struct ContentShareState: Equatable {
    private(set) var tileId: Int? = nil
    private(set) var sharerAttendeeId: String? = nil

    /// Only one active share at a time (Chime allows one per meeting): a second
    /// content tile while one is active is ignored.
    mutating func tileAdded(tileId: Int, attendeeId: String) {
        guard self.tileId == nil else { return }
        self.tileId = tileId
        sharerAttendeeId = ContentShareAttendee.baseAttendeeId(attendeeId)
    }

    mutating func tileRemoved(tileId: Int) {
        guard self.tileId == tileId else { return }
        self.tileId = nil
        sharerAttendeeId = nil
    }

    mutating func reset() { tileId = nil; sharerAttendeeId = nil }
}

// MARK: - Bubble roster (names above bubbles; design-notes.md §3)

struct CallBubbleItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case local(tileId: Int?)      // own preview (nil tile = camera off)
        case remoteVideo(tileId: Int)
        case audioOnly(attendeeId: String)
    }
    let id: String
    let kind: Kind
    /// nil = unresolved (neutral glyph, no label text, VoiceOver "Participant").
    let name: String?

    var accessibilityText: String {
        switch kind {
        case .local(let tile):        return tile == nil ? "You, video off" : "You, video on"
        case .remoteVideo:            return "\(name ?? "Participant"), video on"
        case .audioOnly:              return "\(name ?? "Participant"), audio only"
        }
    }
    var initial: String? { name?.first.map { String($0).uppercased() } }
}

enum CallBubbleRoster {
    /// Own bubble first, then remote video tiles, then audio-only attendees.
    /// Content-share attendees/tiles are never bubbles.
    static func items(
        localTileId: Int?, cameraOn: Bool,
        remoteTileIds: [Int], tileAttendee: [Int: String],
        remoteAttendeeIds: [String], externalUserIds: [String: String],
        names: [String: String]
    ) -> [CallBubbleItem] {
        func name(forAttendee a: String?) -> String? {
            guard let a, let ext = externalUserIds[a] else { return nil }
            return names[ext]
        }
        var out: [CallBubbleItem] = [
            CallBubbleItem(id: "self", kind: .local(tileId: cameraOn ? localTileId : nil), name: "You")
        ]
        var withVideo = Set<String>()
        for t in remoteTileIds {
            let a = tileAttendee[t]
            if let a { withVideo.insert(a) }
            out.append(CallBubbleItem(id: "tile-\(t)", kind: .remoteVideo(tileId: t), name: name(forAttendee: a)))
        }
        for a in remoteAttendeeIds where !withVideo.contains(a) && !ContentShareAttendee.isContent(a) {
            out.append(CallBubbleItem(id: "att-\(a)", kind: .audioOnly(attendeeId: a), name: name(forAttendee: a)))
        }
        return out
    }
}

// MARK: - Attendee -> display name cache

/// Chime ExternalUserId == FellowScript user_id (backend.json). Names come from
/// the same `fetchUser(userId:)` lookup RingMembersSheet.loadRoster uses,
/// resolved lazily per id and cached for the lifetime of the call screen.
@MainActor
final class CallParticipantNames: ObservableObject {
    @Published private(set) var names: [String: String] = [:]
    private var inFlight = Set<String>()

    func resolve(ids: [String], service: DataServiceProtocol?, selfId: String) {
        guard let service else { return }
        for id in ids where !id.isEmpty && id != selfId && names[id] == nil && !inFlight.contains(id) {
            inFlight.insert(id)
            Task { @MainActor [weak self] in
                let user = try? await service.fetchUser(userId: id)
                guard let self else { return }
                self.inFlight.remove(id)
                if let user, !user.username.isEmpty { self.names[id] = user.username }
            }
        }
    }
}

// MARK: - Breathing background model (design-notes.md §6)

struct BreathingBackgroundModel {
    static let period: TimeInterval = 10
    static let minimumInterval: TimeInterval = 1.0 / 15.0
    static let staticPhase: Double = 0.5

    // Opacity caps asserted by tests (WCAG headroom at the brightest point).
    static let aOpacityRange: ClosedRange<Double> = 0.14...0.26
    static let bOpacityRange: ClosedRange<Double> = 0.08...0.16
    static let aRadiusRange: ClosedRange<Double> = 360...440
    static let bRadiusRange: ClosedRange<Double> = 340...400
    static let centerDrift: Double = 0.03

    /// Eased sine, never linear: 0 -> 1 -> 0 over `period`.
    static func phase(at t: TimeInterval) -> Double {
        (1 - cos(2 * Double.pi * t / period)) / 2
    }

    /// The animation (and its timer) runs only when every condition holds.
    static func isAnimating(reduceMotion: Bool, sceneActive: Bool, lowPower: Bool, visible: Bool) -> Bool {
        !reduceMotion && sceneActive && !lowPower && visible
    }

    struct Frame: Equatable {
        var aOpacity: Double, aRadius: Double, aCenter: CGPoint
        var bOpacity: Double, bRadius: Double
    }

    static func frame(phase p: Double) -> Frame {
        func lerp(_ r: ClosedRange<Double>, _ x: Double) -> Double { r.lowerBound + (r.upperBound - r.lowerBound) * x }
        let drift = (p - 0.5) * 2 * centerDrift   // -0.03 ... +0.03
        return Frame(
            aOpacity: lerp(aOpacityRange, p),
            aRadius:  lerp(aRadiusRange, p),
            aCenter:  CGPoint(x: 0.22 + drift, y: 0.18 - drift),  // opposite sign y vs x
            bOpacity: lerp(bOpacityRange, 1 - p),
            bRadius:  lerp(bRadiusRange, 1 - p)
        )
    }
}

// MARK: - Breathing background view

struct CallBreathingBackground: View {
    /// False while the call screen is minimized / off screen.
    let isVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var animating: Bool {
        BreathingBackgroundModel.isAnimating(
            reduceMotion: reduceMotion, sceneActive: scenePhase == .active,
            lowPower: lowPower, visible: isVisible)
    }

    var body: some View {
        Group {
            if animating {
                // Low-rate eased sine: ~15fps is plenty for a 10s cycle. The
                // TimelineView only exists while `animating`, so Reduce Motion /
                // Low Power / background / off-screen leave no timer running.
                TimelineView(.animation(minimumInterval: BreathingBackgroundModel.minimumInterval)) { ctx in
                    gradient(phase: BreathingBackgroundModel.phase(at: ctx.date.timeIntervalSinceReferenceDate))
                }
            } else {
                gradient(phase: BreathingBackgroundModel.staticPhase)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private func gradient(phase: Double) -> some View {
        let f = BreathingBackgroundModel.frame(phase: phase)
        return ZStack {
            Theme.bgPage
            RadialGradient(colors: [Theme.gold.opacity(f.aOpacity), .clear],
                           center: UnitPoint(x: f.aCenter.x, y: f.aCenter.y),
                           startRadius: 10, endRadius: CGFloat(f.aRadius))
            RadialGradient(colors: [Theme.goldLight.opacity(f.bOpacity), .clear],
                           center: UnitPoint(x: 0.82, y: 0.78),
                           startRadius: 10, endRadius: CGFloat(f.bRadius))
            // Constant scrim keeps text legible at the brightest point of the breath.
            Theme.bgPage.opacity(0.30)
        }
    }
}
