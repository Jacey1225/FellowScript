// SOURCE: frontend/src/pages/Account.jsx
// KEY STATE: profileData, agents, events, requests, editLoading, deleteConfirm, agentModal
// INTERACTIONS: edit profile (username/email/password), accept friend requests,
//               create/toggle/delete agents, create/delete events, sign out, delete account
// DEPENDENCY: Theme.swift, Models.swift, AppState.swift
//
// readability #6 (20260904-frontend-arch-sweep): this file used to combine
// AccountViewModel and every section (profile, subscription, agents, events,
// two-factor, privacy/legal/danger-zone) in one 2174-line file, each private
// computed property with no navigable seams beyond in-body `// ──` banners.
// Split into a view-model file plus one file per section, mirroring the
// split already applied to NetworkService.swift (H16). Pure file-
// organization work -- same types, same behavior, no interface change.
// Every section builder/state property that used to be `private` dropped
// that modifier (Swift's `private` only extends to same-file extensions),
// which is what makes it callable from this struct's own extensions living
// in other files -- still invisible outside this app target.
//
// Files: AccountViewModel.swift (+ FSJoinablePlan), AccountView.swift (this
// file -- struct declaration, state, body, and the small pill-control
// helpers shared across every section), AccountView+Profile.swift (profile
// header, stats, plan usage, edit-profile, friend requests),
// AccountView+Subscription.swift, AccountView+Agents.swift,
// AccountView+Events.swift, AccountView+TwoFactor.swift,
// AccountView+Misc.swift (privacy/legal/sign-out/danger-zone),
// AccountSupportingViews.swift (StatBox/NewAgentSheet/TimeZonePickerSheet/
// EventRow/IdentifiableString -- already-independent view structs this file
// also used to define).

import SwiftUI
import Combine
import PhotosUI

// ── Root account view ─────────────────────────────────────────────────────────
struct AccountView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @StateObject var vm = AccountViewModel()
    @ObservedObject var store = StoreKitManager.shared

    // Subscription: member-count picker for a new plan (1-8)
    @State var selectedMemberCount = 1
    // Subscription: host's in-progress seat-count edit on an active plan
    @State var editMemberCount: Int? = nil
    // Subscription: "What's included" benefits disclosure — shared by the
    // active-subscriber and pre-purchase states, which are mutually exclusive
    // branches of the same section, so one toggle is safe. Pure UI display
    // state with no backend/VM logic behind it, so it's local @State rather
    // than @Published on AccountViewModel (matches showBlockedUsers below).
    @State var showBenefits = false

    // Edit profile
    @State var username     = ""
    @State var email        = ""
    @State var password     = ""
    @State var timezone     = "UTC"

    // Profile photo (task 20260905-profile-photo): mirrors the web client's
    // Account.jsx state names 1:1 (photoUploading/photoError/photoJustUpdated)
    // -- same three-step wire contract (presigned S3 POST → upload → confirm),
    // same plain-spinner-while-uploading (Q17) and brief crossfade-on-
    // completion (Q18) conventions, native PhotosPicker idiom instead of a
    // bare <input type=file>.
    @State var photoPickerItem: PhotosPickerItem? = nil
    @State var photoUploading  = false
    @State var photoError:     String? = nil
    @State var photoJustUpdated = false

    // Agents
    @State var newAgentRole   = ""
    @State var activeSheet:   AccountSheet? = nil
    @State var renameAgentId: String? = nil
    @State var renameText     = ""

    enum AccountSheet: Identifiable {
        case newAgent
        case newEvent
        case editEvent(FSHeartbeat)
        case timezonePicker
        var id: String {
            switch self {
            case .newAgent:                 return "newAgent"
            case .newEvent:                 return "newEvent"
            case .editEvent(let e):         return "event-\(e.id)"
            case .timezonePicker:           return "timezonePicker"
            }
        }
    }

    @State var showBlockedUsers = false

    // Two-factor authentication (email code)
    @State var mfaEnabled = false
    @State var mfaLoading = false
    @State var mfaMsg = ""
    @State var mfaMsgIsError = false
    @State var showMfaSetup = false
    @State var mfaSetupCode = ""
    @State var mfaSetupLoading = false
    @State var showMfaDisable = false
    @State var mfaDisablePassword = ""
    @State var mfaDisableLoading = false

    // Danger zone
    @State var deleteConfirm  = ""
    @State var showDeleteAlert = false
    @State var deleteAccountError: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()

                // Warm bloom ground (shared visual language with Chat/Notes/Dashboard).
                RadialGradient(colors: [Color(hex: "#D4922A").opacity(0.20), .clear],
                               center: UnitPoint(x: 0.12, y: 0.16), startRadius: 10, endRadius: 380)
                    .ignoresSafeArea()
                RadialGradient(colors: [Color(hex: "#B8761D").opacity(0.12), .clear],
                               center: UnitPoint(x: 0.92, y: 0.60), startRadius: 10, endRadius: 340)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // ── Profile header (avatar + name) ────────────────────
                        profileHeader

                        // ── Stats (mirrors StatBox row) ───────────────────────
                        statsSection

                        // ── Subscription ───────────────────────────────────────
                        subscriptionSection

                        // ── Plan usage ─────────────────────────────────────────
                        usageSection

                        // ── Edit profile ───────────────────────────────────────
                        editProfileSection

                        // ── Friend requests ────────────────────────────────────
                        friendRequestsSection

                        // ── Agents ──────────────────────────────────────────────
                        agentsSection

                        // ── Events ──────────────────────────────────────────────
                        eventsSection

                        // ── Two-Factor Authentication ──────────────────────────
                        twoFactorSection

                        // ── Privacy & Safety ───────────────────────────────────
                        privacySafetySection

                        // ── Legal ───────────────────────────────────────────────
                        legalSection

                        // ── Sign Out ────────────────────────────────────────────
                        signOutSection

                        // ── Danger zone ─────────────────────────────────────────
                        dangerZone
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, Theme.spacingMD)
                    .padding(.bottom, 150) // clears the floating tab bar
                }
                // Pull-to-refresh (task 20260831-interaction-polish-conventions):
                // wired to this screen's existing reload method
                // (refreshAccountData(), below) rather than replaying the
                // whole `.task` verbatim — see that method's own comment for
                // why the StoreKit calls stay out of it. `vm.isLoading` isn't
                // read anywhere in this view's body (unlike NotesListView/
                // ChatRootView, which gate their whole list on it), so this
                // can call vm.load() directly with no risk of blanking the
                // screen mid-refresh.
                .refreshable {
                    await refreshAccountData()
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(isPresented: $showBlockedUsers) {
                BlockedUsersView(userId: appState.currentUser?.user_id ?? "", service: appState.service)
            }
        }
        // Shared keyboard-dismiss convention (task
        // 20260831-interaction-polish-conventions) — covers every TextField
        // in this screen's Edit Profile / Danger Zone sections below.
        .dismissesKeyboardOnScrollAndTap()
        .task {
            if let user = appState.currentUser {
                await vm.load(service: appState.service, user: user)
                // Seed local @State from the freshly-fetched profile (vm.profileData),
                // not the stale pre-fetch `user` snapshot captured above — falling back
                // to `user` only if the fetch somehow left profileData nil.
                let freshUser = vm.profileData ?? user
                username = freshUser.username
                email    = freshUser.email
                timezone = freshUser.timezone
                mfaEnabled = freshUser.mfa_enabled
                // StoreKit: start listening, load products, and push any active
                // entitlements to the backend before reading the subscription.
                store.startListening()
                await store.loadProducts()
                await store.syncEntitlements(userId: user.user_id, service: appState.service)
                await vm.loadSubscription(userId: user.user_id)
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .newAgent:
                NewAgentSheet(role: $newAgentRole) {
                    let role = newAgentRole
                    newAgentRole = ""
                    Task { await vm.createAgent(role: role) }
                }
            case .newEvent:
                EventSetupSheet(agents: vm.agents, groups: vm.groups) { agentId, prompt, timestamps, groupId, notesPublic, idempotencyKey in
                    Task { await vm.createEvent(agentId: agentId, prompt: prompt, timestamps: timestamps, groupId: groupId, notesPublic: notesPublic, idempotencyKey: idempotencyKey) }
                }
            case .editEvent(let event):
                // idempotencyKey is generated per Save tap for every
                // EventSetupSheet attempt (task
                // 20260905-heartbeat-timezone-duplicate-bugs), but only the
                // create path (above) has a server-side dedup mechanism to
                // consume it (POST .../heartbeat) -- updateHeartbeat (PUT
                // .../update_heartbeats) is not a duplicate-row-creating
                // endpoint, so the token is intentionally discarded here.
                EventSetupSheet(agents: vm.agents, groups: vm.groups, existing: event) { agentId, prompt, timestamps, groupId, notesPublic, _ in
                    Task { await vm.updateEvent(event, agentId: agentId, prompt: prompt, timestamps: timestamps, groupId: groupId, notesPublic: notesPublic) }
                }
            case .timezonePicker:
                TimeZonePickerSheet(selected: timezone) { picked in
                    timezone = picked
                }
            }
        }
        .alert("Free Plan Limit", isPresented: Binding(
            get:  { vm.limitMsg != nil },
            set:  { if !$0 { vm.limitMsg = nil } }
        )) {
            Button("OK", role: .cancel) { vm.limitMsg = nil }
        } message: {
            Text(vm.limitMsg ?? "")
        }
        .alert("Agent Error", isPresented: Binding(
            get:  { vm.agentMsg != nil },
            set:  { if !$0 { vm.agentMsg = nil } }
        )) {
            Button("OK", role: .cancel) { vm.agentMsg = nil }
        } message: {
            Text(vm.agentMsg ?? "")
        }
        .alert("Account Details", isPresented: Binding(
            get:  { vm.statsMsg != nil },
            set:  { if !$0 { vm.statsMsg = nil } }
        )) {
            Button("OK", role: .cancel) { vm.statsMsg = nil }
        } message: {
            Text(vm.statsMsg ?? "")
        }
        .alert("Friend Request Error", isPresented: Binding(
            get:  { vm.friendMsg != nil },
            set:  { if !$0 { vm.friendMsg = nil } }
        )) {
            Button("OK", role: .cancel) { vm.friendMsg = nil }
        } message: {
            Text(vm.friendMsg ?? "")
        }
        .alert("Couldn't Delete Account", isPresented: Binding(
            get:  { deleteAccountError != nil },
            set:  { if !$0 { deleteAccountError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteAccountError = nil }
        } message: {
            Text(deleteAccountError ?? "")
        }
        .alert("Rename Agent", isPresented: Binding(
            get:  { renameAgentId != nil },
            set:  { if !$0 { renameAgentId = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let id = renameAgentId {
                    vm.renameAgent(id: id, name: renameText.trimmingCharacters(in: .whitespaces))
                }
                renameAgentId = nil
            }
            Button("Cancel", role: .cancel) { renameAgentId = nil }
        } message: {
            Text("Enter a display name for this agent.")
        }
        .alert("Delete Account", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                let uid = appState.currentUser?.user_id ?? ""
                Task {
                    // C4: a swallowed failure here previously signed the user
                    // out unconditionally, so a failed deletion looked
                    // identical to a successful one -- only sign out on
                    // confirmed success; surface an alert otherwise.
                    do {
                        try await appState.service.deleteUser(userId: uid)
                        await MainActor.run { appState.signOut() }
                    } catch {
                        await MainActor.run {
                            deleteAccountError = (error as? LocalizedError)?.errorDescription
                                ?? "Could not delete your account. Please try again."
                        }
                    }
                }
            }
        } message: {
            Text("This will permanently delete your account and all data. This cannot be undone.")
        }
    }

    // ── Shared pill controls (reused across sections; recipes cited in the design
    // doc's §1 "Reused visual language" table — gradient CTA pill mirrors
    // GroupActivityWidget's "Continue reading" pill / Note-Editor Save pill; ghost
    // outline pill and ghost icon+label pill mirror NoteEditorView's header chips) ─
    func gradientPill(_ title: String, compact: Bool = false) -> some View {
        Text(title)
            .font(.inter(compact ? Theme.fontXS : Theme.fontSM, weight: .semibold))
            .foregroundColor(Color(hex: "#24170A"))
            .padding(.horizontal, compact ? 14 : 20)
            .frame(height: compact ? 32 : 36)
            .background(
                LinearGradient(colors: [Color(hex: "#EDAB3C"), Color(hex: "#D4922A"), Color(hex: "#B8761D")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(Capsule())
    }

    func ghostPill(_ title: String, compact: Bool = false,
                   labelColor: Color = Theme.textSecondary,
                   strokeColor: Color = Theme.parchment.opacity(0.14)) -> some View {
        Text(title)
            .font(.inter(compact ? Theme.fontXS : Theme.fontSM))
            .foregroundColor(labelColor)
            .padding(.horizontal, compact ? 12 : 16)
            .frame(height: compact ? 32 : 36)
            .overlay(Capsule().stroke(strokeColor, lineWidth: 1))
    }

    func ghostLabelPill(icon: String, _ title: String, color: Color = Theme.gold) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title).font(.inter(Theme.fontSM))
        }
        .foregroundColor(color)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .overlay(Capsule().stroke(Theme.parchment.opacity(0.14), lineWidth: 1))
    }
}

// ── Helper to make String Identifiable for sheet(item:) ──────────────────────
struct IdentifiableString: Identifiable {
    let value: String
    var id: String { value }
}
