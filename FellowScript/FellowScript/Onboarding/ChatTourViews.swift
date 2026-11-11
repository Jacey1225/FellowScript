// ChatTourViews.swift -- task 20261106-chat-tour (step 4).
//
// SwiftUI for the chat tour, matching the Jacey-approved SQUIDWARD frames
// (design-approval.md): the Chat tab offer card (frame E1), the Account
// "Replay chat tour" row (E2), the recap (E4), and the small wiring modifiers
// the chat screens use to report real actions to OnboardingEngine.
//
// Coordinator: ContentView feeds fresh suppression inputs; the offer card
// evaluates ChatTourStore.shouldOffer and presents itself at most once.
// Nothing here touches TourPromptStore or PostTourPromptsStore.

import SwiftUI
import Combine

// MARK: - Options from the live app

extension ChatTourOptions {
    /// Built fail-closed from what the user and server really have right now.
    /// `inviteLink` stays false: there is no client-side capability for invite
    /// links (the section hides itself on a server 404), so the tour never
    /// promises one.
    static func make(friendCount: Int, capabilities c: FSCapabilities) -> ChatTourOptions {
        ChatTourOptions(
            hasFriends: friendCount > 0,
            threads: c.isEnabled("threads"),
            inviteLink: false,
            joinRequests: c.isEnabled("join_requests"),
            announcements: c.isEnabled("chat_announcements"),
            messageActions: c.messageReactionsEnabled || c.isEnabled("chat_replies") || c.messagePinsEnabled
        )
    }
}

// MARK: - Coordinator

/// Owns whether the Chat tab offer card is showing. Shared (like OnboardingEngine)
/// so the Chat tab and the Account row reach the same instance without plumbing.
@MainActor
final class ChatTourOfferCoordinator: ObservableObject {
    static let shared = ChatTourOfferCoordinator()

    @Published var suppression = ChatTourOfferSuppression()
    @Published private(set) var isPresented = false

    var store: ChatTourStore
    /// Set by ContentView; reads the real friends list and capabilities.
    var optionsProvider: @MainActor () -> ChatTourOptions = { .none }

    init(store: ChatTourStore = ChatTourStore()) { self.store = store }

    /// The card shows once it was presented, unless a higher-priority flow took over.
    var isVisible: Bool {
        guard isPresented, OnboardingEngine.shared.state == nil else { return false }
        let reason = suppression.blockingReason
        return reason == nil || reason == .notOnChatTab
    }

    /// Counted at presentation, so a dismissal or a start never brings it back.
    func evaluate() {
        guard !isPresented, store.shouldOffer(suppression: suppression) else { return }
        store.recordShown()
        isPresented = true
    }

    func start() {
        guard store.isFeatureEnabled else { return }
        isPresented = false
        OnboardingEngine.shared.startChatTour(options: optionsProvider())
    }

    func dismiss() {
        isPresented = false
        store.recordDismissed()
    }
}

// MARK: - Chat tab offer card (frame E1)

struct ChatTourOfferCard: View {
    @ObservedObject private var coordinator = ChatTourOfferCoordinator.shared
    @ObservedObject private var engine = OnboardingEngine.shared

    var body: some View {
        // The .task needs a view that is always in the hierarchy: on an empty Group
        // it never runs, so evaluate() would never fire while the card is hidden.
        ZStack {
            Color.clear
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .task(id: coordinator.suppression) { coordinator.evaluate() }
            if coordinator.isVisible && engine.state == nil {
                card.transition(.opacity)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CHAT TOUR")
                .font(.system(size: 11, weight: .semibold)).tracking(1)
                .foregroundColor(Theme.gold.opacity(0.85))
            Text("New to Chat?")
                .font(.fsCardHeading).foregroundColor(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("A one-minute hands-on tour of messages, calls and groups. Skip any step.")
                .font(.system(size: 14)).foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(action: { coordinator.dismiss() }) {
                    Text("Not now")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Not now")
                .accessibilityHint("Hides the chat tour offer. You can replay it from Account.")
                .accessibilityIdentifier("chatTour.offer.dismiss")
                Spacer()
                Button(action: { coordinator.start() }) {
                    HStack(spacing: 6) {
                        Text("Start tour")
                        Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Theme.ink)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(Theme.goldGradient))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start tour")
                .accessibilityIdentifier("chatTour.offer.start")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.formCardRadius, style: .continuous).fill(Theme.cardGlassGray))
        .overlay(RoundedRectangle(cornerRadius: Theme.formCardRadius, style: .continuous).strokeBorder(Theme.borderGray, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Account row (frame E2)

/// Second row of the "Guided tour" card, under "Replay onboarding". Hidden unless
/// the chat tour flag is on; the section itself is hidden while a flow is active.
struct ChatTourReplayRow: View {
    private var store: ChatTourStore { ChatTourStore() }

    var body: some View {
        if store.isEntryAvailable {
            let isNew = store.offerState != .started && store.offerState != .completed
            Button(action: { ChatTourOfferCoordinator.shared.start() }) {
                HStack(spacing: 10) {
                    Label("Replay chat tour", systemImage: "bubble.left.and.bubble.right")
                        .font(.system(size: Theme.fontBody))
                        .foregroundColor(Theme.parchment)
                    if isNew {
                        Text("NEW")
                            .font(.system(size: 10, weight: .bold)).tracking(0.8)
                            .foregroundColor(Theme.gold)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.6), lineWidth: 1))
                            .accessibilityHidden(true)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(isNew ? "Replay chat tour, new" : "Replay chat tour")
            .accessibilityHint("Walk through messages, calls and groups in Chat, step by step")
            .accessibilityIdentifier("chatTour.account.row")
        }
    }
}

/// Recovery row for a chat tour that is running but cannot continue (for example
/// a saved tour whose card has no screen to draw on). The "Guided tour" card hides
/// the other rows while a flow is active, so this is the way out. Only a chat tour
/// is ever ended here; a first-run flow is untouched.
struct ChatTourEndRow: View {
    @ObservedObject private var engine = OnboardingEngine.shared

    var body: some View {
        if engine.isChatTour {
            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                sectionLabelText
                Button(action: { engine.endChatTour() }) {
                    HStack {
                        Label("End chat tour", systemImage: "xmark.circle")
                            .font(.system(size: Theme.fontBody))
                            .foregroundColor(Theme.parchment)
                        Spacer()
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("End chat tour")
                .accessibilityHint("Stops the chat tour. You can replay it from here afterwards.")
                .accessibilityIdentifier("chatTour.account.end")
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .glassCard(cornerRadius: 20)
        }
    }

    private var sectionLabelText: some View {
        Text("CHAT TOUR IN PROGRESS")
            .font(.system(size: 11, weight: .semibold)).tracking(1)
            .foregroundColor(Theme.gold.opacity(0.85))
    }
}

// MARK: - Recap (frame E4)

struct ChatTourRecapView: View {
    @ObservedObject private var engine = OnboardingEngine.shared

    var body: some View {
        ZStack {
            Color.clear.warmBloomBackground()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("You know your way around Chat")
                                .font(.fsSheetTitle).foregroundColor(Theme.textPrimary)
                                .accessibilityAddTraits(.isHeader)
                            Text("Everything here lives in the Chat tab whenever you need it.")
                                .font(.fsBody).foregroundColor(Theme.textSecondary)
                        }
                        VStack(spacing: 0) {
                            let rows = OnboardingCue.chatRecapRows(options: engine.state?.chatOptions ?? .none)
                            ForEach(Array(rows.enumerated()), id: \.element.cueID) { idx, row in
                                if idx > 0 { Divider().overlay(Theme.borderGray) }
                                rowView(row)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: Theme.formCardRadius, style: .continuous).fill(Theme.cardGlassGray))
                        .overlay(RoundedRectangle(cornerRadius: Theme.formCardRadius, style: .continuous).strokeBorder(Theme.borderGray, lineWidth: 1))
                    }
                    .padding(.horizontal, 16).padding(.top, 64).padding(.bottom, 24)
                    .frame(maxWidth: 560).frame(maxWidth: .infinity)
                }
                FSPinnedActionBar(primaryTitle: "Done", onPrimary: { engine.finishRecap() })
                    .frame(maxWidth: 560)
            }
        }
        .accessibilityIdentifier("chatTour.recap")
    }

    @ViewBuilder
    private func rowView(_ row: ChatTourRecapRow) -> some View {
        let done = engine.state?.chatCueDone(row.cueID) == true
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                if done {
                    Circle().fill(Theme.gold).frame(width: 24, height: 24)
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.ink)
                } else {
                    Circle().strokeBorder(Theme.fieldBorder, lineWidth: 2).frame(width: 24, height: 24)
                }
            }
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.fsLabel).foregroundColor(done ? Theme.textPrimary : Theme.textSecondary)
                Text(row.whereToFind)
                    .font(.fsHelper).foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 56, alignment: .top)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(done ? "\(row.title), done" : "\(row.title), not done yet. Find it: \(row.whereToFind)")
    }
}

// MARK: - Wiring for the chat screens

/// Thread screen (DM or group): hosts the coach card and reports real actions.
/// Values are passed in (not the view model) so this adds no observation.
struct ChatTourThreadWiring: ViewModifier {
    let contact: FSContact
    let ackRevision: Int
    let failedCount: Int
    let inThread: Bool
    let anchorMessageId: String?

    func body(content: Content) -> some View {
        content
            .environment(\.chatTourAnchorMessageId, anchorMessageId)
            .onboardingCoach(surfaces: [.chatThreadSheet])
            .onAppear {
                OnboardingEngine.shared.report(contact.type == .group ? .groupThreadOpened : .dmOpened)
            }
            .onDisappear { OnboardingEngine.shared.surfaceDismissed(.chatThreadSheet) }
            // The server acknowledged a send: the message is really sent.
            .onChange(of: ackRevision) { _, _ in
                if contact.type == .friend, !inThread { OnboardingEngine.shared.report(.dmMessageSent) }
            }
            .onChange(of: failedCount) { old, new in
                if new > old, contact.type == .friend {
                    OnboardingEngine.shared.reportFailure(.dmMessageSent, message: "We couldn't send that message. Try again.")
                }
            }
    }
}

extension View {
    func chatTourThreadWiring(contact: FSContact, ackRevision: Int, failedCount: Int, inThread: Bool,
                              anchorMessageId: String?) -> some View {
        modifier(ChatTourThreadWiring(contact: contact, ackRevision: ackRevision, failedCount: failedCount,
                                      inThread: inThread, anchorMessageId: anchorMessageId))
    }

    /// Group info (sheet or inline panel): coach card and the "opened" signal.
    func chatTourGroupInfoWiring() -> some View {
        self
            .onboardingCoach(surfaces: [.groupInfoSheet])
            .onAppear { OnboardingEngine.shared.report(.groupInfoOpened) }
            .onDisappear { OnboardingEngine.shared.surfaceDismissed(.groupInfoSheet) }
    }
}

private struct ChatTourAnchorMessageKey: EnvironmentKey {
    static let defaultValue: String? = nil
}
extension EnvironmentValues {
    /// Chat tour: id of the message that carries the "press and hold" spotlight.
    var chatTourAnchorMessageId: String? {
        get { self[ChatTourAnchorMessageKey.self] }
        set { self[ChatTourAnchorMessageKey.self] = newValue }
    }
}

/// Id of the viewer's last message, the spotlight target of the "press and hold" step.
enum ChatTourAnchors {
    static func lastOwnMessageId(_ messages: [FSMessage]) -> String? {
        messages.last(where: { $0.mine })?.id
    }
}
