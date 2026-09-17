// SOURCE: frontend/src/context/AuthContext.jsx
// DEPENDENCY: Models.swift, MockDataService.swift
// Global EnvironmentObject — replaces React's AuthContext.
// Mirrors signIn / signOut / updateUser from AuthContext.jsx.
// To use the live backend: change `MockDataService.shared` → `NetworkService.shared`.

import SwiftUI
import Combine
import UserNotifications

struct BibleNavTarget: Equatable {
    let book: String
    let chapter: Int
    let verse: Int
}

@MainActor
final class AppState: ObservableObject {

    @Published var currentUser: FSUser?
    @Published var isAuthenticated = false
    @Published var pendingBibleNav: BibleNavTarget? = nil
    @Published var pendingChatContact: FSContact? = nil   // set to open a chat from another tab
    // Set when the account predates a material Terms of Service change (e.g.
    // the Guideline 1.2 zero-tolerance rewrite) — the UI should block on a
    // re-consent screen until acceptTerms() is called.
    @Published var termsReacceptRequired = false
    // Set when Apple created this account without a real name/email (only ever
    // supplied on the very first authorization) — blocks on a screen asking the
    // user to set them manually, since Apple can never resupply them.
    @Published var needsProfileCompletion = false

    // Persisted across launches via UserDefaults (mirrors localStorage in AuthContext.jsx)
    @AppStorage("fs_user_id")        private var storedUserId:   String = ""
    @AppStorage("fs_username")       private var storedUsername:  String = ""
    @AppStorage("fs_email")          private var storedEmail:     String = ""

    // ── Unread conversation tracking (task 20260913-chat-unread-badges) ──────
    // Client-local last-read marker per conversation, keyed by FSContact.id (a
    // group id or a friend's own user id -- both are stable, globally-unique
    // ids in this schema, so one dictionary covers friends and groups without
    // a special case, per the intake spec's "one generic mechanism" decision).
    // Persisted via UserDefaults, same as storedUserId/storedUsername above --
    // client-local only, per the intake spec's explicit scope: this does not
    // survive a reinstall or sync across a user's other devices.
    @AppStorage("fs_last_read_timestamps") private var storedLastReadData: Data = Data()

    // Aggregate count of friend/group conversations with unread messages --
    // the Chat tab badge's source of truth. Always recomputed wholesale by
    // recomputeUnreadConversationCount(contacts:) below, never incremented/
    // decremented by hand, so it can't drift from what hasUnread(_:) would
    // say for each individual contact. Agents are excluded structurally:
    // FSAgent never flows through hasUnread/markRead/this at all.
    @Published var unreadConversationCount: Int = 0

    // Pure change-notification counter, bumped by markRead(_:) -- lets a view
    // that owns the full contacts list (ChatRootView) know a read-marker
    // changed and it should recompute unreadConversationCount, even though
    // markRead(_:) alone can't touch that aggregate itself (it only knows
    // about the one contact being marked read, not the full friend+group set).
    @Published private(set) var lastReadVersion: Int = 0

    private var lastReadTimestamps: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: storedLastReadData)) ?? [:] }
        set { storedLastReadData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// True when `contact` has a message newer than the last time its thread
    /// was opened. A conversation never opened before (no stored marker yet)
    /// counts as unread as soon as it has any message -- matches the intake
    /// spec's recommended answer to "what counts as seen?": only opening the
    /// thread clears it, not merely the contact list loading/refreshing.
    func hasUnread(_ contact: FSContact) -> Bool {
        guard let latest = parseFlexibleISO8601(contact.lastMessageAt) else { return false }
        guard let lastReadRaw = lastReadTimestamps[contact.id],
              let lastRead = parseFlexibleISO8601(lastReadRaw) else { return true }
        return latest > lastRead
    }

    /// Records `contact`'s thread as read as of its own latest known message
    /// -- not the device's current time -- so this stays correct even if a
    /// live WebSocket delivery and this call race, and never needs its own
    /// ISO8601 formatting. Called once, from ChatThreadView's `.task`, the
    /// moment that specific thread is actually opened (never merely from the
    /// chat list being visible or the tab being selected).
    func markRead(_ contact: FSContact) {
        guard !contact.lastMessageAt.isEmpty else { return }
        var timestamps = lastReadTimestamps
        timestamps[contact.id] = contact.lastMessageAt
        lastReadTimestamps = timestamps
        lastReadVersion += 1
    }

    /// Recomputes `unreadConversationCount` from the caller's current
    /// combined friend + group contacts -- ChatRootView is the one place
    /// that owns both arrays together, so it's the one that calls this,
    /// whenever those arrays change or `lastReadVersion` advances.
    func recomputeUnreadConversationCount(contacts: [FSContact]) {
        unreadConversationCount = contacts.filter { hasUnread($0) }.count
    }

    let service: DataServiceProtocol

    init(service: DataServiceProtocol = MockDataService.shared) {
        self.service = service
        restoreSession()
    }

    private func restoreSession() {
        guard !storedUserId.isEmpty else { return }
        let uid = storedUserId
        currentUser     = FSUser(user_id: uid, username: storedUsername, email: storedEmail)
        isAuthenticated = true
        // Task 20260916-callkit-voip-ring: a killed-state cold launch that
        // lands straight into an already-authenticated session (exactly the
        // scenario VoIP push wake-up needs to work for) should register
        // whatever VoIP token PushKit already minted at launch, not wait for
        // a fresh sign-in that may never happen this session.
        registerCachedVoipTokenIfNeeded()
        // Addendum to task 20260905-profile-photo-avatar-gaps: the bare
        // FSUser rebuilt above from @AppStorage carries no
        // `profile_photo_url` (or any other server-only field) -- until
        // something refreshed it, every surface reading `currentUser` (this
        // chat thread's own-sent-message bubble avatar via
        // MessageDisplayGroup.grouped's `me:` param, HeroHeader, ...) would
        // show initials-only for a photo that was actually uploaded in a
        // *previous* session, not because no photo is set. Refresh it in
        // the background here -- same cache-first-then-fresh-fetch shape
        // already used by AccountViewModel.load()/DashboardViewModel.load()/
        // NotesViewModel -- best-effort: a failed fetch just leaves the bare
        // cached user in place, same as before this fix.
        Task { [weak self] in
            guard let self, let fresh = try? await self.service.fetchUser(userId: uid) else { return }
            // Guards against a sign-out (or a different sign-in) racing
            // ahead of this fetch -- only apply if the session is still this
            // same user.
            guard self.storedUserId == uid else { return }
            self.updateUser(fresh)
        }
    }

    func signIn(username: String, password: String) async throws {
        let user = try await service.signIn(username: username, password: password)
        persist(user)
        requestPushNotifications()
    }

    func signUp(username: String, email: String, password: String, termsAccepted: Bool) async throws {
        let user = try await service.signUp(username: username, email: email, password: password, termsAccepted: termsAccepted)
        persist(user)
        requestPushNotifications()
    }

    func signInWithGoogle(credential: String, termsAccepted: Bool) async throws {
        let user = try await service.signInWithGoogle(credential: credential, termsAccepted: termsAccepted)
        persist(user)
        requestPushNotifications()
    }

    func signInWithApple(identityToken: String, fullName: String?, email: String?, termsAccepted: Bool) async throws {
        let user = try await service.signInWithApple(
            identityToken: identityToken, fullName: fullName, email: email, termsAccepted: termsAccepted
        )
        persist(user)
        requestPushNotifications()
    }

    /// Completes a login paused by signIn() throwing `.mfaRequired` — verifies
    /// the emailed code and finishes signing in exactly as a normal login would.
    func completeMfaLogin(userId: String, code: String) async throws {
        let user = try await service.verifyMfaLogin(userId: userId, code: code)
        persist(user)
        requestPushNotifications()
    }

    /// Records acceptance of the current Terms after a re-consent gate was shown.
    /// Throws on failure so the blocking re-consent screen can stay up and show
    /// an error instead of clearing the gate — and thus letting the user past a
    /// required consent step — regardless of whether the server actually
    /// recorded the acceptance.
    func acceptTerms() async throws {
        guard let uid = currentUser?.user_id else { return }
        try await service.acceptTerms(userId: uid)
        termsReacceptRequired = false
    }

    /// Sets a real username/email after Apple sign-in created the account
    /// without them. Throws on failure so the view can show an error inline.
    func completeProfile(username: String, email: String) async throws {
        guard let uid = currentUser?.user_id else { return }
        let user = try await service.updateUser(userId: uid, body: ["username": username, "email": email])
        updateUser(user)
        needsProfileCompletion = false
    }

    func signOut() {
        storedUserId    = ""
        storedUsername  = ""
        storedEmail     = ""
        currentUser     = nil
        isAuthenticated = false
        // Task 20260913-chat-unread-badges: wipe this device's last-read
        // markers too, same reasoning as the cache clear below -- otherwise
        // a second account signing in on this device would inherit the
        // previous user's read/unread state for conversation ids that
        // happen to collide (e.g. the same group id, or a mutual friend).
        storedLastReadData     = Data()
        unreadConversationCount = 0
        lastReadVersion += 1
        // Wipe cached data so the next account never sees the previous user's notes,
        // groups, highlights, messages, or account info.
        Task { await DiskCache.shared.clear() }
        // Invalidate the session server-side too — best-effort. Local sign-out
        // above has already happened unconditionally (this device should never
        // stay "logged in" locally just because a network call failed), but
        // previously no call was ever made, so the server-side cookie/session
        // row stayed valid for up to 30 days after an on-device "sign out".
        Task { try? await service.logout() }
    }

    func updateUser(_ patch: FSUser) {
        storedUserId   = patch.user_id
        storedUsername = patch.username
        storedEmail    = patch.email
        currentUser    = patch
    }

    private func persist(_ user: FSUser) {
        storedUserId   = user.user_id
        storedUsername = user.username
        storedEmail    = user.email
        currentUser    = user
        isAuthenticated = true
        termsReacceptRequired = user.terms_reaccept_required
        needsProfileCompletion = user.needs_profile_completion
        // Task 20260916-callkit-voip-ring: same catch-up as
        // restoreSession() above, for the fresh-sign-in path.
        registerCachedVoipTokenIfNeeded()
    }

    func requestPushNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                // First time — show the system permission dialog
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    guard granted else { return }
                    DispatchQueue.main.async {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
            case .authorized, .provisional, .ephemeral:
                // Already granted — just refresh the token
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            case .denied:
                break
            @unknown default:
                // UNAuthorizationStatus is a non-frozen system enum -- match
                // StoreKitManager.swift's convention (purchase()/restore())
                // so a future SDK adding a new case gets a compiler warning
                // here instead of silently falling into `default:` forever.
                break
            }
        }
    }

    /// Called when the user taps a session-created/session-reminder push
    /// (FellowScriptApp.AppDelegate's `didReceive response:` posts
    /// `.sessionPushTapped` with the push's `group_id`). Reuses the existing
    /// `pendingChatContact` cross-tab navigation (predates this task — see
    /// DashboardView.openFriendChat / ChatRootView's onChange) rather than a
    /// new mechanism.
    ///
    /// `group_id` is one of two shapes, per `DevotionManager.resolve_members`
    /// mirroring `is_authorized`'s own three-way membership split: a real
    /// group id, or a DM room key `"uidA|uidB"` (see
    /// `ChatThreadViewModel.roomKey`). A DM key resolves to the *other*
    /// user id (a DM's `FSContact.id` is the friend's id, not the room key
    /// itself) so `ChatThreadViewModel.roomKey` recomputes the same key the
    /// push's own room key already was.
    func openSession(groupId: String) {
        guard let uid = currentUser?.user_id, !groupId.isEmpty else { return }
        if groupId.contains("|") {
            guard let friendId = groupId.split(separator: "|").map(String.init).first(where: { $0 != uid }) else { return }
            pendingChatContact = FSContact(id: friendId, name: "", type: .friend)
        } else {
            pendingChatContact = FSContact(id: groupId, name: "", type: .group)
        }
    }

    /// Called when the user taps a ring push (task 20260916-call-ring-members
    /// -- FellowScriptApp.AppDelegate's `didReceive response:` posts
    /// `.ringPushTapped` with the push's `devotion_id`/`group_id`, discriminated
    /// from the plain session-created push above via the push's own
    /// `action: "ring"` field). Unlike `openSession(groupId:)`, which only
    /// ever navigates to the session's chat thread, this jumps straight into
    /// *joining the live call* -- the whole point of a ring -- by resolving
    /// the full `FSSession` (CallController.start(session:) needs the object,
    /// not just its id) via the same `fetchSessionsForContact` the chat
    /// thread's own session list already uses, then handing it to
    /// `CallController.shared.start(session:service:userId:)` exactly as
    /// ChatThreadView's/SessionDetailSheet's own "Join" buttons do.
    ///
    /// Falls back to the plain `openSession(groupId:)` navigation if the
    /// session can no longer be resolved (e.g. it ended before the tap
    /// landed) -- landing on the chat thread is a strictly better outcome
    /// than doing nothing on tap.
    func joinRingedCall(devotionId: String, groupId: String) {
        guard let uid = currentUser?.user_id, !devotionId.isEmpty, !groupId.isEmpty else { return }
        Task { @MainActor in
            let sessions = (try? await service.fetchSessionsForContact(contactId: groupId)) ?? []
            if let session = sessions.first(where: { $0.id == devotionId }) {
                CallController.shared.start(session: session, service: service, userId: uid)
            } else {
                openSession(groupId: groupId)
            }
        }
    }

    func registerDeviceToken(_ token: String) {
        guard let uid = currentUser?.user_id else { return }
        // No UI surface for this background sync (nothing polls "is my token
        // registered?"), so a log line is the only signal on failure — but it
        // must not vanish outright the way `try?` let it before, since a failed
        // registration means this device silently never receives push reminders.
        Task {
            do {
                try await service.registerDeviceToken(userId: uid, token: token)
            } catch {
                print("Device token registration failed: \(error.localizedDescription)")
            }
        }
    }

    /// Task 20260916-callkit-voip-ring: registers this device's PushKit VoIP
    /// token, distinct from (and never a substitute for) registerDeviceToken
    /// above -- a VoIP token is a different token type in Apple's system,
    /// stored server-side in its own `voip_device_tokens` table (backend
    /// step 1) so the ring send path can tell "no VoIP token registered"
    /// (`"no_voip_token"`) apart from "no plain APNs token"
    /// (`"unreachable"`). Same fail-loud-but-non-blocking posture as
    /// registerDeviceToken: nothing polls registration status, so a log line
    /// is the only signal on failure, but it's never silently swallowed.
    func registerVoipDeviceToken(_ token: String) {
        guard let uid = currentUser?.user_id else { return }
        Task {
            do {
                try await service.registerVoipDeviceToken(userId: uid, token: token)
            } catch {
                print("VoIP device token registration failed: \(error.localizedDescription)")
            }
        }
    }

    /// Catches up on a PushKit VoIP token PushKit already minted before
    /// sign-in (or before this launch's `.onReceive(.voipTokenReceived)`
    /// subscription even existed) -- PushKit issues this eagerly at launch
    /// (VoipCallManager.swift), unlike the plain APNs token, which is only
    /// requested later via requestPushNotifications(). Called from both
    /// restoreSession() (cold launch, already signed in) and persist(_:)
    /// (a fresh sign-in) so a killed-state launch that lands straight into
    /// an already-authenticated session still ends up with a registered
    /// VoIP token, not just one requested going forward.
    private func registerCachedVoipTokenIfNeeded() {
        if let cachedToken = VoipCallManager.shared.latestVoipToken {
            registerVoipDeviceToken(cachedToken)
        }
    }
}
