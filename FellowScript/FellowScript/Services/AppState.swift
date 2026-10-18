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

/// Validated share-link targets (see AppLink); Identifiable so ContentView can
/// present each confirm screen with `.sheet(item:)`.
struct PendingFriendLink: Identifiable, Equatable {
    let username: String
    var id: String { username }
}
struct PendingGroupLink: Identifiable, Equatable {
    let publicId: String
    var id: String { publicId }
}

@MainActor
final class AppState: ObservableObject {

    @Published var currentUser: FSUser?
    @Published var isAuthenticated = false
    @Published var pendingBibleNav: BibleNavTarget? = nil
    /// iPad workspace: Bible reader "Add to Note" hands the long-pressed verse here;
    /// WorkspaceView focuses the Notes panel and NotesListView opens its inline
    /// editor with the verse attached, then clears it. iPhone keeps its sheet.
    @Published var pendingNoteDraft: VerseNoteDraft? = nil
    @Published var pendingChatContact: FSContact? = nil   // set to open a chat from another tab
    /// Task 20261012-share-verses-notes-in-chat: a verse/note picked for "Send in
    /// chat". The chat thread for `contact` sends it over the one chat socket
    /// once it has loaded, then clears this. Memory only.
    @Published var pendingChatShare: PendingChatShare? = nil
    /// Task 20260929-announcement-push-widget: set by an announcement push tap;
    /// the group's chat widget consumes it (opens the viewer) once mounted.
    @Published var pendingAnnouncementOpen: PendingAnnouncementOpen? = nil
    /// Task 20261001-message-threads: set by a thread push tap; the group's
    /// chat view consumes it once mounted (opens the group chat, then the thread).
    @Published var pendingThreadOpen: PendingThreadOpen? = nil
    /// Task 20261016-push-notifications-and-ui: friend-request push tap -> Account tab,
    /// Friend Requests section (AccountView consumes and clears it).
    @Published var pendingFriendRequestsOpen = false
    /// Join-request push tap: group id whose info sheet the chat opens once mounted.
    @Published var pendingGroupInfoOpen: String? = nil
    // Set when the account predates a material Terms of Service change (e.g.
    // the Guideline 1.2 zero-tolerance rewrite) — the UI should block on a
    // re-consent screen until acceptTerms() is called.
    @Published var termsReacceptRequired = false
    // Set when Apple created this account without a real name/email (only ever
    // supplied on the very first authorization) — blocks on a screen asking the
    // user to set them manually, since Apple can never resupply them.
    @Published var needsProfileCompletion = false

    /// Task 20261002-shared-foundation: server feature capabilities. Starts
    /// (and falls back to) all-off; never set from anything but a fully valid
    /// 200 response. See refreshCapabilities().
    @Published private(set) var capabilities: FSCapabilities = .allOff
    private var capabilitiesFetchedAt: Date = .distantPast
    private var capabilitiesSeq = 0

    /// Task 20260929-group-invite-links: the invite token the user arrived with
    /// (Universal Link / custom scheme). Mirrored into the Keychain by
    /// PendingInviteStore so it survives sign-in, sign-up, and a cold launch;
    /// cleared exactly once (see clearPendingInvite()).
    @Published var pendingInviteToken: String? = nil
    /// True while a signed-out user is off signing in / up for a pending
    /// invite -- hides the join screen without discarding the token.
    @Published var inviteDeferredForAuth = false

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

    // Internal (not private) so AppState+UnreadSeeding.swift can seed baselines.
    var lastReadTimestamps: [String: String] {
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
        // Task 20261016-notification-badges-logic: unread = the newest message
        // is confidently from someone else AND not yet opened. An unknown
        // sender (nil: cached contact, undecodable last message) is never
        // unread (throw-not-fabricate: do not guess), and the current user's
        // own message never is (Task 20260920-chat-self-sent-unread-badge:
        // sending advances lastMessageAt without re-triggering markRead).
        // member_joined system lines never reach lastMessageAt (contact-list
        // loads omit include_system).
        guard let senderId = contact.lastMessageSenderId,
              let currentUserId = currentUser?.user_id,
              senderId != currentUserId else { return false }
        if let lastReadRaw = lastReadTimestamps[contact.id],
           let lastRead = parseFlexibleISO8601(lastReadRaw) {
            return latest > lastRead
        }
        // No marker. Once this user's baseline has been seeded (first
        // successful contacts load), a conversation without a marker is
        // unread only if its newest message postdates the seed, so a
        // reinstall or first launch never floods old history as unread.
        if let seed = unreadSeedDate { return latest > seed }
        return true
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

    /// App-level badge state (task 20261016-notification-badges-logic): pending
    /// friend requests and join-request counts, plus the refresh orchestration.
    /// Its changes are forwarded to AppState.objectWillChange in init so every
    /// existing `appState` observer re-renders.
    let badges = BadgeCountsStore()
    private var badgesForward: AnyCancellable?

    let service: DataServiceProtocol

    /// True once the server has told us (an authenticated request's 401, or a
    /// refused chat-socket handshake) that this session ended. Cached content
    /// stays readable; chat shows a "Sign in again" banner. Cleared by sign-in
    /// and sign-out. Task 20261017-chat-ws-reconnect-stuck.
    @Published private(set) var sessionEnded = false
    private var sessionEndLatch = SessionEndLatch()
    private var sessionEndObserver: AnyCancellable?

    /// Idempotent; ignored when nobody is signed in.
    func markSessionEnded() {
        guard isAuthenticated, sessionEndLatch.mark() else { return }
        sessionEnded = true
    }

    /// Also called by the chat banner's Retry before it re-probes the server.
    func clearSessionEnded() {
        sessionEndLatch.reset()
        if sessionEnded { sessionEnded = false }
    }

    init(service: DataServiceProtocol = MockDataService.shared) {
        self.service = service
        sessionEndObserver = NotificationCenter.default.publisher(for: .sessionEndedByServer)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.markSessionEnded() }
        badgesForward = badges.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        badges.owner = self
        restoreSession()
        if isAuthenticated, let uid = currentUser?.user_id { badges.hydrate(userId: uid) }   // first-frame badges
        pendingInviteToken = PendingInviteStore.load()
    }

    // ── Capabilities (task 20261002-shared-foundation) ───────────────────────

    /// One fetch per launch / sign-in / foreground (foreground calls are
    /// throttled). Fail closed: any error or malformed body leaves every
    /// feature off and terms treated as current. When the server says the
    /// signed-in user has not accepted the current Terms, the existing
    /// re-consent gate (termsReacceptRequired -> TermsReacceptView) is raised;
    /// this never lowers that flag (acceptTerms() does).
    func refreshCapabilities(force: Bool = false) {
        guard let uid = currentUser?.user_id, isAuthenticated else {
            capabilitiesSeq += 1
            capabilities = .allOff
            return
        }
        if !force, Date().timeIntervalSince(capabilitiesFetchedAt) < 15 { return }
        capabilitiesFetchedAt = Date()
        capabilitiesSeq += 1
        let seq = capabilitiesSeq
        Task { [weak self] in
            guard let self else { return }
            let fetched: FSCapabilities
            do { fetched = try await self.service.fetchCapabilities() } catch { fetched = .allOff }
            // Drop a stale result (sign-out, different user, or a newer fetch).
            guard seq == self.capabilitiesSeq, self.currentUser?.user_id == uid else { return }
            self.capabilities = fetched
            if !fetched.termsCurrent { self.termsReacceptRequired = true }
        }
    }

    // ── Invite links (task 20260929-group-invite-links) ──────────────────────

    /// Entry point for onOpenURL / onContinueUserActivity. Only the exact invite
    /// (/join) and share (/u, /v, /g) shapes are acted on; everything else is
    /// ignored. A newer link replaces any pending one (no silent merge).
    func handleIncomingURL(_ url: URL) {
        if let token = InviteLink.token(from: url) {
            setPendingInvite(token)
        } else if let link = AppLink.parse(url) {
            routeShareLink(link)
        }
    }

    // ── Share links (task 20261011-ios-share-notes-highlights) ───────────────

    /// A friend / group link waiting for the confirm screen. Memory only; never
    /// persisted and never logged. Presented by ContentView once the app is ready.
    @Published var pendingFriendLink: PendingFriendLink? = nil
    @Published var pendingGroupLink: PendingGroupLink? = nil
    /// A verse link waiting for the main screen to be ready (then handed to the
    /// existing `pendingBibleNav` path by ContentView).
    @Published var pendingVerseLink: BibleNavTarget? = nil
    /// A share link received while signed out: held in memory, released at sign-in.
    private var deferredShareLink: AppLink?

    /// Signed in: queue it for presentation. Signed out: hold it until auth.
    /// Neither path sends anything; friend/group links only open a confirm screen.
    func routeShareLink(_ link: AppLink) {
        guard isAuthenticated else { deferredShareLink = link; return }
        deferredShareLink = nil
        switch link {
        case .friend(let username): pendingFriendLink = PendingFriendLink(username: username)
        case .group(let publicId):  pendingGroupLink = PendingGroupLink(publicId: publicId)
        case .verse(let book, let chapter, let verse):
            pendingVerseLink = BibleNavTarget(book: book, chapter: chapter, verse: verse)
        }
    }

    /// Called when authentication completes.
    func releaseDeferredShareLink() {
        guard isAuthenticated, let link = deferredShareLink else { return }
        routeShareLink(link)
    }

    func clearShareLinks() {
        deferredShareLink = nil
        pendingFriendLink = nil
        pendingGroupLink = nil
        pendingVerseLink = nil
        pendingChatShare = nil
    }

    func setPendingInvite(_ token: String) {
        guard InviteLink.isWellFormed(token) else { return }
        if !PendingInviteStore.save(token) {
            print("[AppState] pending invite could not be saved to the Keychain; holding it in memory only")
        }
        pendingInviteToken = token
        inviteDeferredForAuth = false
    }

    func clearPendingInvite() {
        PendingInviteStore.clear()
        pendingInviteToken = nil
        inviteDeferredForAuth = false
    }

    /// After a successful join: open that group's chat on the Chat tab.
    func openJoinedGroup(groupId: String, name: String) {
        guard !groupId.isEmpty else { return }
        pendingChatContact = FSContact(id: groupId, name: name, type: .group)
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
        refreshCapabilities(force: true)
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

    func signUp(username: String, email: String, password: String, termsAccepted: Bool, inviteCode: String? = nil) async throws {
        let user = try await service.signUp(username: username, email: email, password: password,
                                            termsAccepted: termsAccepted, inviteCode: inviteCode)
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
        let signedOutUserId = currentUser?.user_id ?? storedUserId
        clearSessionEnded()
        pendingNoteDraft = nil   // in-memory verse draft must not outlive the session
        clearPendingInvite()
        clearShareLinks()
        storedUserId    = ""
        storedUsername  = ""
        storedEmail     = ""
        currentUser     = nil
        isAuthenticated = false
        capabilitiesSeq += 1
        capabilities    = .allOff
        capabilitiesFetchedAt = .distantPast
        // Task 20260913-chat-unread-badges: wipe this device's last-read
        // markers too, same reasoning as the cache clear below -- otherwise
        // a second account signing in on this device would inherit the
        // previous user's read/unread state for conversation ids that
        // happen to collide (e.g. the same group id, or a mutual friend).
        storedLastReadData     = Data()
        clearUnreadSeed(forUserId: signedOutUserId)
        badges.clear(forUserId: signedOutUserId)
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
        clearSessionEnded()
        badges.hydrate(userId: user.user_id)   // this user's persisted badges, never the previous user's
        termsReacceptRequired = user.terms_reaccept_required
        needsProfileCompletion = user.needs_profile_completion
        refreshCapabilities(force: true)
        // Task 20260916-callkit-voip-ring: same catch-up as
        // restoreSession() above, for the fresh-sign-in path.
        registerCachedVoipTokenIfNeeded()
    }

    func requestPushNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                // Task 20261008-post-tour-prompts: a brand-new install's system
                // dialog is deferred to the post-tour pre-prompt (its "Enable
                // notifications" lifts the deferral). Existing users are never
                // deferred.
                if PostTourPromptsStore().defersSystemPushDialog { return }
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

    /// Called when the user taps an announcement push: opens the group chat,
    /// then the widget opens the viewer (falls back to just the chat if the
    /// announcement is gone).
    func openAnnouncement(groupId: String, announcementId: String) {
        guard !groupId.isEmpty, !announcementId.isEmpty else { openSession(groupId: groupId); return }
        pendingAnnouncementOpen = PendingAnnouncementOpen(groupId: groupId, announcementId: announcementId)
        openSession(groupId: groupId)
    }

    /// Called when the user taps a thread push (`action: "thread_message"`,
    /// task 20261001-message-threads): opens the group chat first (the
    /// existing session/chat navigation), then the chat view opens the thread.
    /// A push without a thread id degrades to just opening the chat.
    func openThread(groupId: String, threadId: String) {
        guard !groupId.isEmpty else { return }
        if !threadId.isEmpty {
            pendingThreadOpen = PendingThreadOpen(groupId: groupId, threadId: threadId)
        }
        openSession(groupId: groupId)
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


struct PendingAnnouncementOpen: Equatable {
    let groupId: String
    let announcementId: String
}

/// Task 20261001-message-threads: a thread push tap waiting for its group chat.
struct PendingThreadOpen: Equatable {
    let groupId: String
    let threadId: String
}
