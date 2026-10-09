// SOURCE: components/MessagingSidebar.jsx (ChatView), components/SessionCreator.jsx,
//         components/SessionWidget.jsx, hooks/useSessions.js
// KEY STATE: messages, text, showMembers, showSessionCreator, sessions
// INTERACTIONS: send message, toggle member list, + new study session,
//               session banner "View Details", keyboard avoidance
// DEPENDENCY: Theme.swift, Models.swift
//
// VISUAL: warm-dark-bloom restyle matching chat.html/schedule.html (the
// migrated ChatSchedule prototype). Custom in-body header (mirrors
// ChatRootView.swift's own header convention) replaces the native
// NavigationStack toolbar so the back button, identity, and "Schedule" pill
// can share the same visual language as the rest of this screen. Message
// bubbles are grouped Slack-style via MessageGroupRow (Chat/MessageGroupRow.swift).
// Presentation-only — same ChatThreadViewModel, same websocket lifecycle,
// same member/session/report data flows; no new navigation, no new fetches.
// Reference: .claude/pipeline/20260809-chat-schedule-migrate-fellowscript/,
// /Users/jaceysimpson/Vscode/mockups/chat-schedule/chat.html,
// /Users/jaceysimpson/Vscode/mockups/chat-schedule/schedule.html.
//
// NOTE: the mockups' "Active now" presence dot and "X is typing" indicator
// are mock-only (no real presence/typing-status field on FSContact/FSMessage
// exists anywhere in the app) and are intentionally NOT reproduced here —
// same "no fabricated data" precedent already established in ChatRootView.swift's
// ContactRow.
//
// EMBER GLASS (task 20260827-ember-glass-chat-rewrite, design-notes.md):
// §1 elevation — every surface here (Reconnecting pill, SessionBanner,
// SessionCreatorSheet fields) drops its shadow (there wasn't one to begin
// with here) in favor of Theme.topEdgeHighlight, matching PillButton/
// WidgetCard/message bubbles — one elevation language, no mixing. §11/§12 —
// adds the same whole-canvas ambient wash already shared by ChatRootView/
// NotesListView/NoteEditorView (zero new tokens) plus small focal blooms
// behind the header avatar and the SessionBanner calendar badge. §13 — real
// day-boundary detection (ChatThreadRow/DayDividerRow in MessageGroupRow.swift)
// interleaved into the message list.

import SwiftUI
import UIKit
import Combine

// ── ViewModel (WebSocket + history) ──────────────────────────────────────────

@MainActor
final class ChatThreadViewModel: ObservableObject {
    @Published var messages: [FSMessage] = []
    @Published var sessions: [FSSession] = []
    // Task 20260904-messaging-attachments: the sender's own optimistic echo
    // of an attachment-carrying message (see sendMessage below) — keyed by
    // FSMessage.id. See MessageAttachments.swift's LocalAttachmentPreview
    // doc comment for why this exists.
    @Published var localAttachmentPreviews: [String: LocalAttachmentPreview] = [:]
    // Task 20260905-profile-photo: username → photo URL for every *other*
    // participant in this thread, resolved once per load() (see below) --
    // FSMessage.sender is a plain display-name string with no id/photo of
    // its own, so this is threaded into MessageDisplayGroup.grouped(...)
    // by ChatThreadView rather than requiring a backend change to stamp a
    // photo onto every message.
    @Published var photoByUsername: [String: String] = [:]
    // Surfaced in the view as a small "Reconnecting…" banner. Previously a
    // dropped socket (network blip, backgrounding, Cloudflare/nginx idle
    // timeout, or the server evicting a stale connection) gave no visible
    // signal at all — see backend step 8 finding #2.
    @Published var isConnected: Bool = true
    // Task 20260910-chat-message-disappear-reentry: ids (FSMessage.id) of an
    // optimistic echo (see sendMessage below) whose send the backend
    // explicitly rejected/failed to save (a {"type":"error",...} frame —
    // see receiveLoop()'s handleSendError). MessageGroupRow reads this to
    // render an inline "tap to retry" line on the affected bubble instead of
    // letting it silently vanish on the next thread reload, per
    // design-notes.md's decision to reuse StagedAttachmentChipView's exact
    // failed-upload pattern.
    @Published var failedMessageIds: Set<String> = []

    // Task 20260910-chat-message-disappear-reentry: FIFO queue of
    // client-generated messageIds still awaiting confirmation, oldest first.
    // Neither the ordinary delivered frame nor the error frame carries a
    // client-supplied correlation id (design-notes.md "Correlating an error
    // frame to *which* pending message failed"), so an inbound error frame
    // is matched to the oldest still-unconfirmed send -- a documented
    // approximation, not exact correlation. There is no explicit success ack
    // today, so an id that's never popped as failed is implicitly treated as
    // sent; this isn't actively pruned beyond that (in-memory only, reset by
    // the next load()).
    private var pendingSendIds: [String] = []
    // Retains the StagedAttachment used for a given optimistic message's
    // send, keyed by FSMessage.id, purely so retryFailedMessage(_:contact:userId:)
    // below can resend with the exact same attachment -- FSMessage alone
    // never carries enough to reconstruct one (no S3 object key on the wire
    // to the client). Mirrors localAttachmentPreviews' keying/reset
    // discipline (never actively pruned; load() replacing `messages`
    // wholesale is the natural reset point).
    private var pendingAttachmentByMessageId: [String: StagedAttachment] = [:]

    // ── Pagination (task 20261001-chat-pagination) ───────────────────────────
    // Behavioural reference: the web client (frontend/src/lib/chatPaging.js,
    // hooks/useMessaging.js). Paging is opt-in per thread: only when the SF
    // capabilities client reports chat_pagination (groups) / chat_pagination_dm
    // (DMs) does load() ask for ?limit=; false/missing is the unchanged legacy
    // full-history fetch (and no client_ref is sent, so no ack comes back).
    static let initialPageLimit = 30
    static let olderPageLimit   = 30
    /// DiskCache keeps only the newest window of a paged thread, so a long
    /// scrolled-back session never persists its whole history.
    static let cacheWindow      = 50

    /// True when this thread was opened with a page envelope.
    @Published private(set) var pagingEnabled = false
    @Published private(set) var hasMoreOlder  = false
    @Published private(set) var isLoadingOlder = false
    /// Set when an older-page fetch failed; the view shows a retry control and
    /// does not auto-retry until it is cleared.
    @Published var olderLoadFailed = false
    /// Bumped each time an older page actually merged rows in (the view
    /// re-anchors its scroll position on this, by message id).
    @Published private(set) var olderMergeToken = 0
    /// Bumped when an ack replaced a bubble's local id in place (no count
    /// change), so the view recomputes its id-keyed group/anchor caches.
    @Published private(set) var ackRevision = 0
    private var olderCursor: FSMessageCursor? = nil
    /// Bumped by every load(); a response that returns after the thread was
    /// reloaded is discarded.
    private var loadGeneration = 0

    // Task 20261001-message-threads (10a): the socket lifecycle now lives in
    // ChatSocketOwner (behaviour unchanged). This view model owns exactly ONE
    // owner for its whole life and thread view is a MODE of this same view
    // model (`activeThread`), so a thread never opens a second socket (the
    // server keeps one websocket per user; a new connection replaces the old).
    private let socket = ChatSocketOwner()
    private var wsUserId: String { socket.userId }
    // Task 20260908-chat-userid-exposure: the thread's own contact, plus (for
    // a group) a resolved memberId → username map — both stashed here (not
    // just used locally inside load()) so receiveLoop()'s live-frame path can
    // resolve a raw `from_user` id to a display name the same way the
    // history-fetch path in load() does below, instead of stamping the raw
    // id straight onto FSMessage.sender the way it used to.
    private var currentContact:    FSContact? = nil
    private var groupUsernameById: [String: String] = [:]

    init() {
        socket.onFrame = { [weak self] json in self?.handleFrame(json) }
        socket.onConnectionChange = { [weak self] connected in self?.isConnected = connected }
    }

    /// The session/devotion room id. Must match the web client's `roomKey` so
    /// sessions (and their Chime calls) are shared cross-platform:
    ///   • friend DM → the two user ids sorted and joined with "|"
    ///   • group     → the group id
    static func roomKey(contact: FSContact, userId: String) -> String {
        if contact.type == .friend {
            return [userId, contact.id].sorted().joined(separator: "|")
        }
        return contact.id
    }

    func load(service: DataServiceProtocol, contact: FSContact, userId: String, capabilities: FSCapabilities = .allOff) async {
        let sessionKey = Self.roomKey(contact: contact, userId: userId)
        currentContact = contact
        loadGeneration += 1
        let generation = loadGeneration
        // Gate: false/missing capability = legacy full-history fetch.
        let pageLimit: Int? = capabilities.isEnabled(contact.type == .group ? "chat_pagination" : "chat_pagination_dm")
            ? Self.initialPageLimit : nil

        // ── Cache-first: show the last-seen thread instantly ─────────────────────
        // Keyed by sessionKey (sorted [userId, contact.id] for a friend DM, or
        // the group id) rather than bare contact.id — every other DiskCache
        // call site already namespaces by user, and bare contact.id let two
        // different accounts sharing a device collide on the same friend's
        // message-history cache entry.
        if let cached: [FSMessage] = await DiskCache.shared.load([FSMessage].self, forKey: "messages:\(sessionKey)") {
            messages = cached
        }
        if let cached: [FSSession] = await DiskCache.shared.load([FSSession].self, forKey: "sessions:\(sessionKey)") {
            sessions = cached
        }

        if contact.type == .group {
            // Runs concurrently with the message fetch (no dependency between
            // them) -- resolveGroupMemberPhotos now also returns a
            // memberId → username map (task 20260908-chat-userid-exposure) so
            // every fetched message's raw `from_user` sender id can be
            // stamped with the real username below, instead of rendering the
            // raw id the way MessageDisplayGroup/MessageAttachments used to.
            async let fetchedHistory = service.fetchMessageHistory(userId: userId, contactId: contact.id, isGroup: true, limit: pageLimit)
            let usernameById = await resolveGroupMemberPhotos(contact: contact, service: service, viewerId: userId)
            groupUsernameById = usernameById
            let history = try? await fetchedHistory
            if generation == loadGeneration {
                applyHistory(history, resolve: { self.resolvedMessage($0, senderName: usernameById[$0.sender]) })
            }
        } else {
            let history = try? await service.fetchMessageHistory(userId: userId, contactId: contact.id, isGroup: false, limit: pageLimit)
            // A DM's only other participant is `contact` itself, already
            // resolved (name + photo) by fetchContacts -- no extra fetch
            // needed to turn a raw from_user id into a display name here.
            if generation == loadGeneration {
                applyHistory(history, resolve: { self.resolvedMessage($0, senderName: $0.sender == contact.id ? contact.name : nil) })
            }
            if let photoUrl = contact.photoUrl { photoByUsername[contact.name] = photoUrl }
        }
        sessions = (try? await service.fetchSessionsForContact(contactId: sessionKey)) ?? sessions

        // ── Persist the fresh thread for the next open ───────────────────────────
        // A paged thread persists only its newest window (older pages the
        // user scrolled back through are not written to disk).
        await DiskCache.shared.save(pagingEnabled ? Array(messages.suffix(Self.cacheWindow)) : messages,
                                    forKey: "messages:\(sessionKey)")
        await DiskCache.shared.save(sessions, forKey: "sessions:\(sessionKey)")

        // Gate for sending client_ref on main-chat sends: pagination OR a
        // feature that needs the server id of a just-sent message (Start
        // thread / Delete). Flags off => nothing new is sent.
        ackEnabled = pageLimit != nil || capabilities.isEnabled("threads") || capabilities.isEnabled("message_delete")
        socket.connect(wsBase: service.wsBase, userId: userId)
    }

    /// Applies a fetch result. A failed fetch (nil) keeps whatever the cache
    /// already showed, exactly as before.
    private func applyHistory(_ history: FSMessageHistory?, resolve: (FSMessage) -> FSMessage) {
        switch history {
        case .legacy(let fetched):
            messages = fetched.map(resolve)
            pagingEnabled = false; hasMoreOlder = false; olderCursor = nil
        case .paged(let page):
            messages = page.messages.map(resolve)
            pagingEnabled = true
            hasMoreOlder = page.hasMore
            olderCursor = page.cursor
        case nil:
            break
        }
        olderLoadFailed = false
    }

    /// Fetches the next older page and merges it by message id (rows already
    /// present are skipped; server order is kept, never re-sorted by
    /// timestamp string). Failure sets `olderLoadFailed` for a retry control;
    /// it never fabricates an empty "start of conversation".
    func loadOlder(service: DataServiceProtocol, contact: FSContact, userId: String) async {
        guard pagingEnabled, hasMoreOlder, !isLoadingOlder, let cursor = olderCursor else { return }
        isLoadingOlder = true
        olderLoadFailed = false
        let generation = loadGeneration
        defer { if generation == loadGeneration { isLoadingOlder = false } }
        do {
            // Task 20261001-message-threads: in thread mode the same cursor
            // paging runs against the thread's own messages route.
            let page: FSMessagePage
            if let thread = activeThread {
                page = try await service.fetchThreadMessages(userId: userId, groupId: contact.id, threadId: thread.id,
                                                              limit: Self.olderPageLimit, cursor: cursor)
            } else {
                page = try await service.fetchOlderMessages(userId: userId, contactId: contact.id,
                                                             isGroup: contact.type == .group,
                                                             limit: Self.olderPageLimit, cursor: cursor)
            }
            guard generation == loadGeneration else { return }
            let have = Set(messages.map(\.id))
            let fresh = page.messages.filter { !have.contains($0.id) }
            if !fresh.isEmpty {
                messages = fresh + messages
                olderMergeToken += 1
                UIAccessibility.post(notification: .announcement,
                                     argument: fresh.count == 1 ? "Loaded 1 earlier message" : "Loaded \(fresh.count) earlier messages")
            }
            olderCursor = page.cursor
            hasMoreOlder = page.hasMore
        } catch {
            guard generation == loadGeneration else { return }
            print("[ChatThreadViewModel] older page failed: \(error)")
            olderLoadFailed = true
        }
    }

    /// Resolves every other group member's username → photo URL (task
    /// 20260905-profile-photo) so a group thread's received-message
    /// avatars can show a real photo, not just initials -- `FSMessage.sender`
    /// is a plain username string with no id, so unlike a DM (whose single
    /// other participant is already `contact` itself) this needs its own
    /// per-member `GET /user/{id}` resolution, mirroring the interface gap
    /// the React/legacy-static frontends already closed the same way
    /// (frontend.json) rather than requiring a backend change to stamp a
    /// photo onto every message. Best-effort: a member who fails to
    /// resolve just keeps that sender on the initials fallback.
    ///
    /// Task 20260908-chat-userid-exposure: also returns a memberId →
    /// username map -- the fetch below already reads back `u.username` per
    /// member but used to discard it once the photo was captured, leaving
    /// every group message's `sender` as the raw `from_user` id. `load()`
    /// and `receiveLoop()` use this map to stamp the real username onto
    /// `FSMessage.sender` instead.
    @discardableResult
    private func resolveGroupMemberPhotos(contact: FSContact, service: DataServiceProtocol, viewerId: String) async -> [String: String] {
        let memberIds = contact.toUsers.filter { $0 != viewerId }
        guard !memberIds.isEmpty else { return [:] }
        var usernameById: [String: String] = [:]
        await withTaskGroup(of: (String, String, String?)?.self) { group in
            for mid in memberIds {
                group.addTask {
                    guard let u = try? await service.fetchUser(userId: mid), !u.username.isEmpty else { return nil }
                    return (mid, u.username, u.profile_photo_url)
                }
            }
            for await result in group {
                guard let (mid, username, url) = result else { continue }
                photoByUsername[username] = url
                usernameById[mid] = username
            }
        }
        return usernameById
    }

    /// Stamps a resolved display name onto a fetched/live message's `sender`
    /// (task 20260908-chat-userid-exposure) -- resolved at message-
    /// construction time, before the message ever reaches
    /// MessageDisplayGroup.grouped/MessageAttachments.senderLabel, so those
    /// rendering surfaces keep treating `sender` as a plain display-name
    /// string exactly as their existing doc comments already assert.
    /// `mine` messages already carry an empty `sender` (rendered as "You" by
    /// MessageDisplayGroup.grouped) and are left untouched. A `nil`/empty
    /// `senderName` (failed group-member lookup, or a DM from_user that
    /// doesn't match `contact.id`) leaves the message exactly as fetched --
    /// same raw-id fallback this path already had, not a new regression --
    /// rather than crashing or blanking the label.
    private func resolvedMessage(_ message: FSMessage, senderName: String?) -> FSMessage {
        guard !message.mine, let senderName, !senderName.isEmpty else { return message }
        return FSMessage(
            id: message.id, text: message.text, mine: message.mine, sender: senderName,
            timestamp: message.timestamp, attachmentKind: message.attachmentKind,
            attachmentURL: message.attachmentURL, attachmentMeta: message.attachmentMeta
        )
    }

    /// receiveLoop()'s live-frame counterpart to resolvedMessage(_:senderName:)
    /// above -- resolves a raw `from_user` id using the same DM/group rules
    /// load() applies, off the state load() already stashed (currentContact,
    /// groupUsernameById) rather than re-fetching anything. Returns the raw
    /// id unresolved if load() hasn't run yet (currentContact nil) or the
    /// lookup has no entry for it -- the pre-fix fallback, not a regression.
    private func resolvedSenderName(forRawId rawId: String) -> String {
        guard let contact = currentContact else { return rawId }
        if contact.type == .group {
            return groupUsernameById[rawId] ?? rawId
        }
        return rawId == contact.id ? contact.name : rawId
    }

    /// `attachment` is a fully-uploaded (or gif, never-uploaded)
    /// `StagedAttachment` — the composer is responsible for driving the
    /// upload to completion (and disabling send until it is) before calling
    /// this, per design gate §3.
    func sendMessage(text: String, attachment: StagedAttachment?, contact: FSContact, userId: String) {
        let iso = ISO8601DateFormatter().string(from: Date())
        let messageId = UUID().uuidString
        var body: [String: Any] = ["from_user": userId, "timestamp": iso, "text": text]
        // Task 20261001-chat-pagination: the local UUID doubles as client_ref
        // (36 chars of [0-9a-f-], inside the server's 1-64 [A-Za-z0-9_-]
        // shape) so the sender-only ack can replace this bubble's id in place.
        // Only on a thread opened paged; legacy threads send nothing new.
        if let thread = activeThread {
            // Task 20261001-message-threads: a thread send is a frame on the
            // SAME socket. The group and recipients are derived server-side
            // from thread_id, so no group_id / to_users is sent. client_ref is
            // always sent (thread rows are always paged) so the ack gives the
            // optimistic bubble its server id.
            body = ["type": "thread_message", "thread_id": thread.id, "text": text,
                    "client_ref": messageId, "from_user": userId]
        } else {
            if pagingEnabled || ackEnabled { body["client_ref"] = messageId }
            if contact.type == .group {
                body["group_id"] = contact.id
                body["to_users"] = contact.toUsers
            } else {
                body["to_users"] = [contact.id]
                body["group_id"] = ""
            }
        }

        var attachmentKind: String? = nil
        var attachmentMeta: FSAttachmentMeta? = nil
        var localPreview: LocalAttachmentPreview? = nil

        if let attachment {
            attachmentKind = attachment.kind.rawValue
            body["attachment_kind"] = attachment.kind.rawValue
            body["attachment_meta"] = attachment.outgoingMeta
            switch attachment.kind {
            case .gif:
                attachmentMeta = FSAttachmentMeta(
                    filename: nil, url: attachment.gifResult?.url, previewUrl: attachment.gifResult?.preview_url,
                    width: attachment.gifResult?.width, height: attachment.gifResult?.height
                )
            case .file:
                attachmentMeta = FSAttachmentMeta(filename: attachment.fileName)
            case .image, .video:
                attachmentMeta = FSAttachmentMeta(width: attachment.width, height: attachment.height)
            }
            if case .uploaded(let objectKey) = attachment.uploadState {
                body["attachment_key"] = objectKey
            }
            localPreview = LocalAttachmentPreview(image: attachment.image, videoURL: attachment.videoURL)
        }

        if let data = try? JSONSerialization.data(withJSONObject: body),
           let str  = String(data: data, encoding: .utf8) {
            socket.send(str)
        }
        // No `attachmentURL` on the optimistic echo — image/video render from
        // `localAttachmentPreviews` instead (see field doc comment above);
        // `gifContent` already prefers `attachmentMeta.url` over
        // `attachmentURL`, so a gif renders correctly with neither.
        messages.append(FSMessage(
            id: messageId, text: text, mine: true, sender: "", timestamp: iso,
            attachmentKind: attachmentKind, attachmentURL: nil, attachmentMeta: attachmentMeta
        ))
        if let localPreview {
            localAttachmentPreviews[messageId] = localPreview
        }
        // Task 20260910-chat-message-disappear-reentry: track this optimistic
        // echo as awaiting confirmation so a subsequent {"type":"error",...}
        // frame (handleSendError below) can flag it instead of it silently
        // persisting on-screen until the next reload replaces `messages`
        // wholesale and it simply isn't there.
        pendingSendIds.append(messageId)
        if let attachment {
            pendingAttachmentByMessageId[messageId] = attachment
        }
    }

    /// Tapping a failed bubble's "tap to retry" line (design-notes.md "Retry
    /// action"): resends with the exact same text/attachment the failed
    /// message had, then removes the old failed entry -- from `messages`,
    /// `failedMessageIds`, `localAttachmentPreviews`, and
    /// `pendingAttachmentByMessageId` -- so retrying doesn't leave a
    /// duplicate bubble alongside the new attempt. No confirmation dialog,
    /// matching StagedAttachmentChipView's onRemove "undo-after-the-fact, not
    /// confirm-before-action" convention. A retry that also fails goes
    /// through the exact same pending/fail flow via sendMessage above --
    /// no special-cased dead end.
    func retryFailedMessage(_ messageId: String, contact: FSContact, userId: String) {
        guard let failed = messages.first(where: { $0.id == messageId }) else { return }
        let attachment = pendingAttachmentByMessageId[messageId]
        messages.removeAll { $0.id == messageId }
        failedMessageIds.remove(messageId)
        localAttachmentPreviews.removeValue(forKey: messageId)
        pendingAttachmentByMessageId.removeValue(forKey: messageId)
        sendMessage(text: failed.text, attachment: attachment, contact: contact, userId: userId)
    }

    /// Correlates an inbound `{"type":"error",...}` frame to the oldest
    /// still-unconfirmed optimistic send (design-notes.md's documented FIFO
    /// approximation -- neither frame shape carries a client-generated
    /// correlation id). Logs `reason`/`detail` to console only, same
    /// no-raw-error-in-UI posture as the self-echo-drop `print(...)` in
    /// handleFrame() below (Q17 pet peeve: no technical/raw error dumps).
    ///
    /// Task 20261001-message-threads: `terms_reaccept_required` is not a
    /// failed send to retry. A text-only bubble is pulled back out and its
    /// text returned to the composer (never lost); the view raises the existing
    /// Updated Terms gate through `termsGateSignal`.
    private func handleSendError(reason: String?, detail: String?) {
        print("[ChatThreadViewModel] send failed reason=\(reason ?? "unknown") detail=\(detail ?? "none")")
        guard !pendingSendIds.isEmpty else { return }
        let failedId = pendingSendIds.removeFirst()
        if reason == "terms_reaccept_required" {
            termsGateSignal += 1
            if pendingAttachmentByMessageId[failedId] == nil,
               let idx = messages.firstIndex(where: { $0.id == failedId }) {
                restoredDraft = messages[idx].text
                messages.remove(at: idx)
                localAttachmentPreviews.removeValue(forKey: failedId)
                return
            }
        }
        failedMessageIds.insert(failedId)
    }

    /// Reconciles an `ack` frame with the optimistic bubble (same rule as the
    /// web client's reconcileAck): the bubble whose local id is the acked
    /// `client_ref` is replaced IN PLACE with the server id and stored
    /// timestamp (never appended); if a row with the server id is already
    /// present (a refetch beat the ack) the optimistic bubble is deleted
    /// instead; an unknown client_ref changes nothing. The id-keyed side
    /// tables (local attachment preview, failed/pending sets) follow the id.
    ///
    /// Task 20261001-message-threads: an ack carrying `thread_id` reconciles
    /// only the open thread's list (and only if that thread is still open); an
    /// ack without it belongs to the main chat, which is the stash while a
    /// thread is open.
    private func handleAck(clientRef: String, id: String, timestamp: String?, threadId: String?) {
        if let threadId {
            guard activeThread?.id == threadId else { return }
            if Self.reconcile(&messages, clientRef: clientRef, id: id, timestamp: timestamp) { afterAck(clientRef: clientRef, id: id) }
            return
        }
        if activeThread == nil {
            if Self.reconcile(&messages, clientRef: clientRef, id: id, timestamp: timestamp) { afterAck(clientRef: clientRef, id: id) }
        } else if var st = mainStash {
            if Self.reconcile(&st.messages, clientRef: clientRef, id: id, timestamp: timestamp) {
                st.pendingSendIds.removeAll { $0 == clientRef }
                st.failedMessageIds.remove(clientRef)
                mainStash = st
                pendingAttachmentByMessageId.removeValue(forKey: clientRef)
                if let preview = localAttachmentPreviews.removeValue(forKey: clientRef) { localAttachmentPreviews[id] = preview }
            }
        }
    }

    private func afterAck(clientRef: String, id: String) {
        pendingSendIds.removeAll { $0 == clientRef }
        pendingAttachmentByMessageId.removeValue(forKey: clientRef)
        failedMessageIds.remove(clientRef)
        if let preview = localAttachmentPreviews.removeValue(forKey: clientRef) { localAttachmentPreviews[id] = preview }
        ackRevision += 1
    }

    /// Pure list half of the ack rule. Returns true when `list` held the
    /// optimistic bubble.
    private static func reconcile(_ list: inout [FSMessage], clientRef: String, id: String, timestamp: String?) -> Bool {
        guard let idx = list.firstIndex(where: { $0.id == clientRef }) else { return false }
        if list.contains(where: { $0.id == id }) {
            list.remove(at: idx)
        } else {
            let old = list[idx]
            list[idx] = FSMessage(
                id: id, text: old.text, mine: old.mine, sender: old.sender,
                timestamp: (timestamp?.isEmpty == false ? timestamp! : old.timestamp),
                attachmentKind: old.attachmentKind, attachmentURL: old.attachmentURL, attachmentMeta: old.attachmentMeta
            )
        }
        return true
    }

    func disconnect() { socket.disconnect() }

    // ── App-lifecycle wiring (task 20260902-chat-push-notification-failure) ──
    // Previously the socket was only ever closed by onDisappear (the chat
    // *view* leaving the hierarchy), not by the app being backgrounded. A
    // backgrounded-but-still-foreground-view chat left active_connections[uid]
    // registered server-side well after the app could no longer surface an
    // incoming frame as a notification, so the server's `ws.send_json`
    // "succeeded" and never fell through to the APNs push branch. The backend
    // heartbeat is the real backstop; proactively closing here shrinks the
    // race window for the common graceful-backgrounding case. The reconnect
    // path (handleAppForegrounded) only resumes a connection the socket owner
    // itself closed.
    //
    // Task 20260921-recurring-session-next-occurrence: deliberately does NOT
    // re-fetch `sessions` here (no new client-side polling; re-opening the
    // thread re-runs load()).
    func handleAppBackgrounded() { socket.handleAppBackgrounded() }
    func handleAppForegrounded() { socket.handleAppForegrounded() }

    // ── Live frames ───────────────────────────────────────────────────────────
    // One socket, one dispatch. Every frame the user can receive arrives here
    // in order: ordinary main-chat deliveries (no `type`), ack / error, and the
    // task 20261001-message-threads frames thread_message, message_deleted and
    // message_restored. Unknown types are an explicit no-op.
    private func handleFrame(_ json: [String: Any]) {
        // Task 20260910-chat-message-disappear-reentry: explicit branch on
        // `type` (Q26) -- an ordinary chat delivery frame carries no `type`.
        if let type = json["type"] as? String {
            switch type {
            case "ack":
                // Task 20261001-chat-pagination: sender-only frame for a
                // message sent with client_ref. Never a bubble, never an error.
                if let ref = json["client_ref"] as? String, let ackId = json["id"] as? String {
                    handleAck(clientRef: ref, id: ackId, timestamp: json["timestamp"] as? String,
                              threadId: json["thread_id"] as? String)
                }
            case "error":
                handleSendError(reason: json["reason"] as? String, detail: json["detail"] as? String)
            case "thread_message":
                handleThreadFrame(json)
            case "message_deleted":
                handleMessageDeleted(json)
            case "message_restored":
                handleMessageRestored(json)
            case "thread_deleted":
                handleThreadDeleted(json)
            case "ping":
                break // heartbeat -- no UI action
            default:
                break // unrecognized type -- explicit no-op
            }
            return
        }
        guard let msgText = json["text"] as? String else { return }
        let fromUser = (json["from_user"] as? String) ?? ""
        // Self-echo guard (task 20260902-group-chat-message-duplication): a
        // group send is fanned out to every member in `to_users`, including the
        // sender. The backend no longer re-delivers to the sender, but this
        // stays as defense-in-depth.
        if !fromUser.isEmpty, fromUser == wsUserId {
            print("[ChatThreadViewModel] dropping self-echoed inbound frame from_user=\(fromUser) -- already shown via optimistic local append")
            return
        }
        // Task 20260904-messaging-attachments: attachment_* ride along on the
        // same frame, decoded exactly like the history-load path.
        var attachmentMeta: FSAttachmentMeta? = nil
        if let metaDict = json["attachment_meta"] as? [String: Any], !metaDict.isEmpty,
           let metaData = try? JSONSerialization.data(withJSONObject: metaDict) {
            attachmentMeta = try? JSONDecoder().decode(FSAttachmentMeta.self, from: metaData)
        }
        // Task 20260908-chat-userid-exposure: resolve the raw from_user id to a
        // display name from state load() populated.
        let incoming = FSMessage(
            id:        (json["id"] as? String) ?? UUID().uuidString,
            text:      msgText,
            mine:      false,
            sender:    resolvedSenderName(forRawId: fromUser),
            timestamp: (json["timestamp"] as? String) ?? "",
            attachmentKind: json["attachment_kind"] as? String,
            attachmentURL:  json["attachment_url"] as? String,
            attachmentMeta: attachmentMeta
        )
        // Dedup by id (a live frame for a row a history fetch already
        // delivered must not render twice); a frame without an id always appends.
        let hasId = json["id"] is String
        if activeThread == nil {
            if hasId, messages.contains(where: { $0.id == incoming.id }) { return }
            messages.append(incoming)
        } else if var st = mainStash {
            // A thread is open: the main chat keeps receiving into its stash so
            // nothing is lost when the user goes back.
            if hasId, st.messages.contains(where: { $0.id == incoming.id }) { return }
            st.messages.append(incoming)
            mainStash = st
        }
    }

    private func handleThreadFrame(_ json: [String: Any]) {
        guard let tid = json["thread_id"] as? String, activeThread?.id == tid,
              let msg = FSMessage(threadFrame: json) else { return }
        if messages.contains(where: { $0.id == msg.id }) { return }
        messages.append(msg)
        if var t = activeThread { t.replyCount += 1; activeThread = t }
    }

    /// Set when the open thread was deleted (by anyone, incl. this user) or
    /// turned out not to exist; the view shows it once and clears it.
    @Published var threadGoneNotice: String? = nil

    /// `{type:"thread_deleted", thread_id, group_id}`: tell every list, and
    /// leave the thread gracefully if it is the one being viewed.
    private func handleThreadDeleted(_ json: [String: Any]) {
        guard let tid = json["thread_id"] as? String, !tid.isEmpty, frameBelongsToCurrentGroup(json),
              let gid = currentContact?.id else { return }
        FSThreadChange(groupId: gid, threadId: tid, kind: .deleted).post()
        dropThreadIfOpen(tid)
    }

    private func dropThreadIfOpen(_ tid: String) {
        guard activeThread?.id.lowercased() == tid.lowercased() else { return }
        closeThread()
        threadGoneNotice = "That thread was deleted."
    }

    /// A rename elsewhere (info sheet): keep the open thread's header in step.
    func applyThreadRename(threadId: String, title: String) {
        if var t = activeThread, t.id == threadId { t.title = title; activeThread = t }
    }

    private func handleMessageDeleted(_ json: [String: Any]) {
        guard let id = json["id"] as? String, frameBelongsToCurrentGroup(json) else { return }
        removeMainMessage(id)
        if var t = activeThread, t.rootMessageId == id { t.rootDeleted = true; activeThread = t }
    }

    private func handleMessageRestored(_ json: [String: Any]) {
        guard frameBelongsToCurrentGroup(json), let msg = FSMessage(restoredFrame: json) else { return }
        mutateMain { $0 = fsInsertRestored($0, msg) }
        if var t = activeThread, t.rootMessageId == msg.id {
            t.rootDeleted = false
            t.rootPreview = msg.text
            activeThread = t
        }
    }

    private func frameBelongsToCurrentGroup(_ json: [String: Any]) -> Bool {
        guard let contact = currentContact, contact.type == .group else { return false }
        return (json["group_id"] as? String)?.lowercased() == contact.id.lowercased()
    }

    /// Applies `change` to the main chat's list: the displayed list normally,
    /// the stash while a thread is open.
    private func mutateMain(_ change: (inout [FSMessage]) -> Void) {
        if activeThread == nil {
            change(&messages)
        } else if var st = mainStash {
            change(&st.messages)
            mainStash = st
        }
    }

    private func removeMainMessage(_ id: String) {
        mutateMain { $0.removeAll { $0.id == id } }
    }

    // ── Threads (task 20261001-message-threads) ───────────────────────────────
    // A thread is a MODE of this view model: opening one stashes the main
    // chat's list/paging state, loads the thread's own paged rows into the same
    // `messages` / paging fields (so the view's grouping, scroll, older-page
    // and retry code runs unchanged), and keeps using the same socket. Going
    // back restores the stash exactly. Main-chat frames that arrive meanwhile
    // are written into the stash.

    private struct MainChatStash {
        var messages: [FSMessage]
        var pagingEnabled: Bool
        var hasMoreOlder: Bool
        var olderCursor: FSMessageCursor?
        var olderLoadFailed: Bool
        var pendingSendIds: [String]
        var failedMessageIds: Set<String>
    }

    /// Set while a thread is open; nil in the main chat.
    @Published private(set) var activeThread: FSThreadSummary? = nil
    @Published private(set) var isLoadingThread = false
    /// The thread's first page failed to load (the view shows a retry control;
    /// nothing is fabricated).
    @Published private(set) var threadLoadFailed = false
    /// Bumped when a send hit terms_reaccept_required (the view refreshes
    /// capabilities, which raises the existing Updated Terms gate).
    @Published private(set) var termsGateSignal = 0
    /// Text handed back to the composer after terms_reaccept_required.
    @Published var restoredDraft: String? = nil
    private var mainStash: MainChatStash? = nil
    /// Whether main-chat sends carry a client_ref (see load()).
    private var ackEnabled = false

    var isThreadOpen: Bool { activeThread != nil }

    /// Opens `summary` as the current mode and loads its first page.
    func openThread(_ summary: FSThreadSummary, service: DataServiceProtocol, contact: FSContact, userId: String) async {
        guard contact.type == .group else { return }
        if activeThread?.id == summary.id { return }
        if mainStash == nil {
            mainStash = MainChatStash(messages: messages, pagingEnabled: pagingEnabled, hasMoreOlder: hasMoreOlder,
                                      olderCursor: olderCursor, olderLoadFailed: olderLoadFailed,
                                      pendingSendIds: pendingSendIds, failedMessageIds: failedMessageIds)
        }
        loadGeneration += 1
        activeThread = summary
        messages = []
        pagingEnabled = true
        hasMoreOlder = false
        olderCursor = nil
        olderLoadFailed = false
        isLoadingOlder = false
        pendingSendIds = []
        failedMessageIds = []
        await loadThreadFirstPage(service: service, contact: contact, userId: userId)
    }

    /// Retry / initial load of the open thread's newest page.
    func loadThreadFirstPage(service: DataServiceProtocol, contact: FSContact, userId: String) async {
        guard let thread = activeThread else { return }
        let generation = loadGeneration
        isLoadingThread = true
        threadLoadFailed = false
        defer { if generation == loadGeneration { isLoadingThread = false } }
        do {
            let page = try await service.fetchThreadMessages(userId: userId, groupId: contact.id, threadId: thread.id,
                                                              limit: Self.initialPageLimit, cursor: nil)
            guard generation == loadGeneration, activeThread?.id == thread.id else { return }
            // Keep frames/acks that arrived while the page was in flight.
            let pageIds = Set(page.messages.map(\.id))
            let arrived = messages.filter { !pageIds.contains($0.id) }
            messages = page.messages + arrived
            hasMoreOlder = page.hasMore
            olderCursor = page.cursor
        } catch {
            guard generation == loadGeneration, activeThread?.id == thread.id else { return }
            print("[ChatThreadViewModel] thread load failed: \(error)")
            if let e = error as? FSThreadsError, e == .notFound {
                // Deleted (or never visible): leave non-alarmingly, drop it from lists.
                FSThreadChange(groupId: contact.id, threadId: thread.id, kind: .deleted).post()
                dropThreadIfOpen(thread.id)
                return
            }
            threadLoadFailed = true
        }
    }

    /// Resolves a thread id (push deep link) to its list row, then opens it. A
    /// thread that is not found in the first pages still opens (title falls
    /// back to "Thread"); the messages route is the real authorization check.
    func openThread(id: String, service: DataServiceProtocol, contact: FSContact, userId: String) async {
        var summary: FSThreadSummary? = nil
        var cursorTs: String? = nil
        var cursorId: String? = nil
        for _ in 0..<5 {
            guard let page = try? await service.fetchThreads(userId: userId, groupId: contact.id, limit: 20,
                                                              cursorTimestamp: cursorTs, cursorId: cursorId) else { break }
            if let hit = page.threads.first(where: { $0.id.lowercased() == id.lowercased() }) { summary = hit; break }
            guard page.hasMore else { break }
            cursorTs = page.cursorTimestamp
            cursorId = page.cursorId
        }
        await openThread(summary ?? FSThreadSummary(id: id), service: service, contact: contact, userId: userId)
    }

    /// Back to the main chat; restores the stashed state exactly.
    func closeThread() {
        guard activeThread != nil, let st = mainStash else { return }
        loadGeneration += 1
        activeThread = nil
        mainStash = nil
        messages = st.messages
        pagingEnabled = st.pagingEnabled
        hasMoreOlder = st.hasMoreOlder
        olderCursor = st.olderCursor
        olderLoadFailed = st.olderLoadFailed
        pendingSendIds = st.pendingSendIds
        failedMessageIds = st.failedMessageIds
        isLoadingOlder = false
        isLoadingThread = false
        threadLoadFailed = false
        ackRevision += 1
    }

    /// POST /threads on `message`, then open the returned thread. Throws
    /// FSThreadsError (terms gate / thread limit / not found) for the view.
    func startThread(from message: FSMessage, service: DataServiceProtocol, contact: FSContact, userId: String) async throws {
        let summary = try await service.createThread(userId: userId, groupId: contact.id, messageId: message.id)
        await openThread(summary, service: service, contact: contact, userId: userId)
    }

    // ── Delete / undo (main-chat messages, author only) ───────────────────────

    /// Optimistic delete: the bubble disappears immediately; on failure it is
    /// put back at its time position and the error is rethrown. Returns the
    /// server's undo window.
    func deleteOwnMessage(_ message: FSMessage, service: DataServiceProtocol, contact: FSContact, userId: String) async throws -> FSMessageDeleteResult {
        removeMainMessage(message.id)
        do {
            return try await service.deleteGroupMessage(userId: userId, groupId: contact.id, messageId: message.id)
        } catch {
            mutateMain { $0 = fsInsertRestored($0, message) }
            throw error
        }
    }

    /// Undo within the window. Failure leaves the message deleted.
    func undoDelete(_ message: FSMessage, service: DataServiceProtocol, contact: FSContact, userId: String) async throws {
        try await service.restoreGroupMessage(userId: userId, groupId: contact.id, messageId: message.id)
        mutateMain { $0 = fsInsertRestored($0, message) }
        if var t = activeThread, t.rootMessageId == message.id {
            t.rootDeleted = false
            t.rootPreview = message.text
            activeThread = t
        }
    }

    // ── Action-menu support ───────────────────────────────────────────────────

    /// A message has a server id and is neither in flight nor failed.
    func isSettled(_ message: FSMessage) -> Bool {
        !pendingSendIds.contains(message.id) && !failedMessageIds.contains(message.id)
    }

    /// The user id behind a received group message's sender name (reverse of
    /// the memberId -> username map load() resolved); nil when unknown.
    func senderUserId(for message: FSMessage) -> String? {
        guard !message.mine, let contact = currentContact else { return nil }
        if contact.type == .friend { return contact.id }
        return groupUsernameById.first(where: { $0.value == message.sender })?.key
    }
}

// ── View ──────────────────────────────────────────────────────────────────────

struct ChatThreadView: View {
    let contact: FSContact
    let user:    FSUser?

    @EnvironmentObject var appState: AppState
    @StateObject private var vm = ChatThreadViewModel()

    @Environment(\.dismiss) private var dismiss
    // Drives handleAppBackgrounded()/handleAppForegrounded() below — only
    // .background is treated as "actually gone," not the transient .inactive
    // state SwiftUI also reports for things like a Control Center swipe, an
    // incoming-call/permission overlay, or the app-switcher gesture. Reacting
    // to .inactive too would disconnect (and then have to reconnect) during
    // ordinary foreground interactions that never left the app, which is the
    // opposite of what this task is trying to fix.
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text:        String = ""
    // Task 20260929-group-info-panel: replaces the old inline showMembers
    // strip -- the header now opens GroupInfoSheet (members are hosted in it).
    // The overrides carry server-confirmed rename/photo changes so the header
    // updates immediately; `contact` itself is an immutable `let`.
    @State private var showGroupInfo: Bool = false
    @State private var groupTitleOverride: String? = nil
    @State private var groupPhotoOverride: String?? = nil
    @State private var showSession: Bool   = false
    @State private var showAddMembers: Bool = false

    // ── Message actions + threads (task 20261001-message-threads) ────────────
    @State private var toasts: [ChatToast] = []
    @State private var reportTarget: FSContact? = nil
    @State private var blockConfirmTarget: FSContact? = nil
    /// Main-chat message a Start thread is waiting to resume on after the
    /// Updated Terms gate is accepted.
    @State private var pendingThreadStart: FSMessage? = nil
    @AccessibilityFocusState private var threadTitleFocused: Bool
    @FocusState private var composerFocused: Bool

    // ── Sessions submenu (task 20260920-chat-sessions-submenu) ────────────────
    // Replaces the old always-visible inline SessionBanner + header
    // "Schedule" pill pairing with one entry point: the renamed "Sessions"
    // pill opens this floating, translucent/blurred submenu listing every
    // session for the chat, with the create-session action folded inside it.
    @State private var showSessionsMenu: Bool = false
    // Item-based (rather than reusing `showSession`'s Bool + `.first`
    // convention the old SessionBanner relied on) because any row in the
    // submenu's list -- not just "the next upcoming one" -- can now open a
    // detail sheet, so the sheet needs to know *which* session was tapped.
    @State private var selectedSession: FSSession? = nil

    // Live member state (seeded from `contact`) so newly added members appear
    // immediately without needing a full reload.
    @State private var memberNames: [String] = []
    @State private var memberIds:   [String] = []
    @State private var friends:     [FSContact] = []   // candidates to add

    // Surfaces createGroup/updateGroup rejections (e.g. the content-filter
    // 422 on a disallowed title) instead of the previous silent no-op — see
    // backend step 8 finding #1.
    @State private var membersErrorMsg: String? = nil

    // ── Attachments (task 20260904-messaging-attachments, design gate §1–§3) ──
    @State private var showAttachSheet       = false
    @State private var showPhotoVideoPicker  = false
    @State private var showDocumentPicker    = false
    @State private var showGifSheet          = false
    @State private var stagedAttachment: StagedAttachment? = nil
    @State private var attachmentErrorMsg: String? = nil
    // Third pass on task 20260908-chat-userid-exposure-standalone-media,
    // Bug 2. Both prior attempts routed the Send-button re-render through
    // `StagedAttachment`'s own `@Published var uploadState` -- first via an
    // empty `.onReceive` closure (a genuine no-op: subscribing does nothing
    // by itself), then via an `.onReceive` closure that bumped a dummy
    // @State counter. The second one is textbook-correct SwiftUI and DID
    // pass locally, but a real device still showed Send staying disabled
    // indefinitely (confirmed: not just slow -- literally never enables on
    // its own, only after an unrelated interaction). Rather than keep
    // trusting an indirect Combine-subscription chain I can't fully verify
    // live right now, this mirrors the upload result directly into a plain
    // @State on ChatThreadView itself, set explicitly at every one of
    // `startUpload`'s state transitions (uploading/uploaded/failed) instead
    // of read off `stagedAttachment.uploadState` through an intermediary.
    // `canSend` now reads this instead -- the single most direct, least
    // assumption-laden way to get an async result into this view's own
    // re-render cycle.
    @State private var stagedUploadState: StagedAttachmentUploadState? = nil

    // Memoized (High H12): these two used to be plain computed properties,
    // so SwiftUI re-ran the grouping + day-divider pass in full on every
    // render of this view -- including every composer keystroke (`text`'s
    // @State) and every other unrelated @State toggle, not just an actual
    // new/changed message. Cached in @State now and recomputed only from
    // `.onChange(of: vm.messages.count)` below, which already existed here
    // (for the scroll-to-bottom behavior) as the same "did the message list
    // actually change" signal.
    @State private var messageGroups: [MessageDisplayGroup] = []
    @State private var threadRows:    [ChatThreadRow]       = []

    // Task 20260908-chat-scroll-to-bottom-on-open, second pass: the first
    // pass drove the initial scrollTo imperatively from inside `.task`,
    // right after an `await vm.load(...)` continuation resumed. That does
    // NOT reliably participate in the same SwiftUI update transaction as a
    // synchronous callback like `.onChange`/`.onAppear` -- unlike the
    // already-working `.onChange(of: vm.messages.count)` scroll below,
    // `proxy.scrollTo(id:)` called from a post-await Task continuation can
    // fire before the List has actually re-rendered with the row for that
    // id (SwiftUI hasn't drained the pending state-change transaction yet),
    // silently no-oping. Root-caused live on a real device/real message
    // history after the first pass shipped and still failed to reach the
    // bottom on reopen -- the mock/UI-test fixture's short message list
    // apparently already rendered fast enough to mask this.
    //
    // Fix: don't call scrollTo imperatively at all. `.task` only flips this
    // plain @State flag once loading finishes; the actual scroll happens in
    // `.onChange(of: readyForInitialScroll)` below, alongside the existing
    // `.onChange(of: vm.messages.count)` handler, inside the
    // ScrollViewReader's own closure where `proxy` is directly in scope --
    // that puts it on the exact same synchronous, SwiftUI-transaction-aware
    // path as the new-message case that was already working correctly.
    @State private var readyForInitialScroll = false

    // ── Older-history paging (task 20261001-chat-pagination) ─────────────────
    // Message id of the first row at the moment an older page was requested.
    // After the page merges, the view scrolls back to THAT MESSAGE (by the
    // per-message anchor marker in MessageGroupRow), not to a
    // MessageDisplayGroup.id: a group's id is its first message's id, so it
    // changes whenever an older page merges into the first group.
    @State private var olderAnchorMessageId: String? = nil
    // Whether the "load earlier" header is inside the viewport (real viewport
    // visibility, not LazyVStack realization, so a thread that has not been
    // scrolled to the bottom yet never triggers a load).
    @State private var olderHeaderVisible = false
    // Id of the last message the scroll position was last pinned to; the
    // bottom scroll only runs when the tail actually changed (append), never
    // for a prepend of older rows.
    @State private var lastTailId: String? = nil

    // Task 20261009-chat-jump-to-latest: true while the viewport sits more than
    // `jumpToLatestThreshold` above the end of the content. Purely local view
    // state; the newest page is always resident in vm.messages (older pages
    // only prepend), so scrolling to the last row reaches the newest message
    // in both flag modes.
    @State private var isAwayFromBottom = false
    @ScaledMetric(relativeTo: .body) private var jumpButtonSize: CGFloat = 44
    private let jumpToLatestThreshold: CGFloat = 120

    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Button {
            guard let lastGroup = messageGroups.last else { return }
            withMotionAwareAnimation(.easeOut(duration: 0.25), reduceMotion: reduceMotion) {
                proxy.scrollTo(lastGroup.id, anchor: .bottom)
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Theme.gold)
                .frame(width: jumpButtonSize, height: jumpButtonSize)
                .background(Theme.bgPage)
                .overlay(Circle().stroke(Theme.borderGold, lineWidth: 1))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Circle())
        .padding(.trailing, Theme.spacingMD)
        .padding(.bottom, Theme.spacingSM)
        .accessibilityLabel("Jump to latest messages")
        .accessibilityAddTraits(.isButton)
        .transition(.opacity)
    }

    private func requestOlderPage() {
        guard readyForInitialScroll, olderHeaderVisible,
              vm.pagingEnabled, vm.hasMoreOlder, !vm.isLoadingOlder, !vm.olderLoadFailed,
              let uid = appState.currentUser?.user_id else { return }
        olderAnchorMessageId = vm.messages.first?.id
        Task { await vm.loadOlder(service: appState.service, contact: contact, userId: uid) }
    }

    private func retryOlderPage() {
        vm.olderLoadFailed = false
        requestOlderPage()
    }

    /// Top-of-thread row: spinner while an older page loads, a retry button
    /// after a failure, "Start of conversation" once history is exhausted
    /// (paged threads only -- a legacy thread has no marker).
    @ViewBuilder
    private var olderHistoryHeader: some View {
        if vm.pagingEnabled {
            Group {
                if vm.olderLoadFailed {
                    Button(action: retryOlderPage) {
                        Text("Couldn't load earlier messages. Tap to retry")
                            .font(.inter(Theme.fontXS))
                            .foregroundColor(Theme.error)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Couldn't load earlier messages, retry")
                    .accessibilityHint("Double tap to try again")
                } else if vm.hasMoreOlder {
                    HStack(spacing: 6) {
                        // Only the spinner is "motion"; it is hidden under
                        // Reduce Motion in favor of static text.
                        if !reduceMotion { ProgressView().tint(Theme.gold).scaleEffect(0.75) }
                        Text(vm.isLoadingOlder ? "Loading earlier messages…" : "Earlier messages")
                            .font(.inter(Theme.fontXS))
                            .foregroundColor(Theme.textGoldMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(vm.isLoadingOlder ? "Loading earlier messages" : "Earlier messages available")
                } else if !vm.messages.isEmpty {
                    Text("Start of conversation")
                        .font(.inter(Theme.fontXS))
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Start of conversation")
                }
            }
            .padding(.vertical, Theme.spacingSM)
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                olderHeaderVisible = visible
                if visible { requestOlderPage() }
            }
        }
    }

    // Recomputes both caches from the current vm.messages/user -- called
    // once up front (via `.task`, so the very first render after load()
    // populates vm.messages isn't stuck showing an empty cache) and again
    // any time vm.messages.count changes thereafter.
    private func recomputeMessageGroups() {
        messageGroups = MessageDisplayGroup.grouped(from: vm.messages, me: user, photoByUsername: vm.photoByUsername)
        // Interleaves labeled day-divider rows between MessageDisplayGroups
        // (design gate §13) — real Calendar.isDate(inSameDayAs:) detection,
        // not a cosmetic restyle of the existing plain sender-group hairline.
        threadRows = messageGroups.withDayDividers()
    }

    var body: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()

            // Warm bloom ground (shared visual language with ChatRootView/
            // Notes) — Added item 2: whole-canvas ambient wash, identical
            // values to ChatRootView.swift/NotesListView.swift/NoteEditorView.swift.
            RadialGradient(colors: [Color(hex: "#D4922A").opacity(0.20), .clear],
                           center: UnitPoint(x: 0.12, y: 0.16), startRadius: 10, endRadius: 380)
                .ignoresSafeArea()
            RadialGradient(colors: [Color(hex: "#B8761D").opacity(0.12), .clear],
                           center: UnitPoint(x: 0.92, y: 0.60), startRadius: 10, endRadius: 340)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if vm.isThreadOpen {
                    threadHeader
                    threadRootCard
                } else {
                    header
                }

                // Task 20260929-announcement-push-widget: groups only, directly under the header.
                if !vm.isThreadOpen, contact.type == .group, GroupAnnouncementsConfig.enabled, let uid = user?.user_id {
                    GroupAnnouncementWidgetView(service: appState.service, groupId: contact.id, userId: uid)
                }

                // ── Reconnecting banner (dropped-socket lifecycle state) ───
                // Same vm.isConnected-driven logic as before — restyled into
                // a pill using the Ember Glass elevation language (§1) rather
                // than bare floating text+spinner.
                if !vm.isConnected {
                    HStack(spacing: 6) {
                        ProgressView().tint(Theme.gold).scaleEffect(0.75)
                        Text("Reconnecting…")
                            .font(.inter(Theme.fontXS))
                            .foregroundColor(Theme.textGoldMuted)
                    }
                    .padding(.horizontal, Theme.spacingSM)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.045))
                    .overlay(Capsule().stroke(Theme.borderGoldFaint, lineWidth: 1))
                    .clipShape(Capsule())
                    .topEdgeHighlight(Capsule())
                    .padding(.horizontal, Theme.spacingSM)
                    .padding(.top, Theme.spacingXS)
                    .accessibilityLabel("Reconnecting to chat")
                }

                // ── Message list (Slack-style grouped bubbles + day dividers) ──
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            threadStateView
                            olderHistoryHeader
                            let rows = threadRows
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                switch row {
                                case .group(let group):
                                    MessageGroupRow(
                                        group: group,
                                        localAttachmentPreviews: vm.localAttachmentPreviews,
                                        failedMessageIds: vm.failedMessageIds,
                                        onRetry: { messageId in
                                            let uid = appState.currentUser?.user_id ?? ""
                                            vm.retryFailedMessage(messageId, contact: contact, userId: uid)
                                        },
                                        actionsFor: { message in rowActions(for: message) }
                                    )
                                        .id(row.id)
                                case .dayDivider(_, let label):
                                    DayDividerRow(label: label)
                                        .id(row.id)
                                }
                                // Decision 2 (design step 1, fidelity pass):
                                // no rendered line between two consecutive
                                // same-day groups — only a spacing gap. This
                                // reverses the original Ember Glass design
                                // gate's §13 call to keep a plain unlabeled
                                // hairline here, which didn't actually match
                                // render-2-conversation-thread.png (no line
                                // between non-day-boundary groups at all).
                                // Day-divider hairlines (DayDividerRow) are
                                // untouched — that specific line-flanking-a-
                                // label motif still belongs at day boundaries
                                // only.
                                if index < rows.count - 1,
                                   case .group = row,
                                   case .group = rows[index + 1] {
                                    Color.clear.frame(height: Theme.spacingSM)
                                }
                            }
                        }
                        .padding(.top, 4)
                        .padding(.bottom, Theme.spacingSM)
                    }
                    .onScrollGeometryChange(for: Bool.self) { geo in
                        let distance = geo.contentSize.height + geo.contentInsets.bottom
                            - geo.contentOffset.y - geo.containerSize.height
                        return distance > jumpToLatestThreshold
                    } action: { _, away in
                        withMotionAwareAnimation(.easeOut(duration: 0.2), reduceMotion: reduceMotion) {
                            isAwayFromBottom = away
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isAwayFromBottom && readyForInitialScroll && !messageGroups.isEmpty {
                            jumpToLatestButton(proxy: proxy)
                        }
                    }
                    .onChange(of: vm.messages.count) { _ in
                        recomputeMessageGroups()
                        // Append-only: scroll to the newest group only when the
                        // tail message changed. Prepending an older page leaves
                        // the tail alone (the re-anchor below handles it), and
                        // an ack that swaps a local id in place does not change
                        // the count at all.
                        let tailId = vm.messages.last?.id
                        defer { lastTailId = tailId }
                        guard tailId != lastTailId, let lastGroup = messageGroups.last else { return }
                        withMotionAwareAnimation(.default, reduceMotion: reduceMotion) { proxy.scrollTo(lastGroup.id, anchor: .bottom) }
                    }
                    // An older page merged: keep the reader on the message
                    // they were looking at (by message id; never animated, so
                    // Reduce Motion needs no special case).
                    .onChange(of: vm.olderMergeToken) { _ in
                        recomputeMessageGroups()
                        if let anchor = olderAnchorMessageId {
                            olderAnchorMessageId = nil
                            proxy.scrollTo(MessageGroupRow.anchorId(for: anchor), anchor: .top)
                        }
                    }
                    // An ack replaced a bubble's id in place (same count).
                    .onChange(of: vm.ackRevision) { _ in
                        recomputeMessageGroups()
                        lastTailId = vm.messages.last?.id
                    }
                    // Task 20261001-message-threads: entering/leaving a thread
                    // swaps the whole list (the count can be equal across the
                    // swap, so the count-based handler alone is not enough).
                    .onChange(of: vm.activeThread?.id) { newId in
                        recomputeMessageGroups()
                        lastTailId = vm.messages.last?.id
                        if let lastGroup = messageGroups.last {
                            proxy.scrollTo(lastGroup.id, anchor: .bottom)
                        }
                        if newId != nil {
                            // VoiceOver lands on the thread title; the composer
                            // stays one swipe away.
                            Task {
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                threadTitleFocused = true
                            }
                        }
                    }
                    // Initial-open scroll (see `readyForInitialScroll`'s
                    // declaration above for why this lives here, on the same
                    // synchronous onChange path as the case above, rather
                    // than being called imperatively from `.task`). Snapped,
                    // not animated -- see `.task` below for why.
                    .onChange(of: readyForInitialScroll) { ready in
                        guard ready, let lastGroup = messageGroups.last else { return }
                        lastTailId = vm.messages.last?.id
                        proxy.scrollTo(lastGroup.id, anchor: .bottom)
                        // Short threads keep the header on screen after the
                        // snap; re-check once the scroll has settled.
                        Task {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            requestOlderPage()
                        }
                    }
                }
            }
            // Shared keyboard-dismiss convention (task
            // 20260831-interaction-polish-conventions) — covers header/
            // banners/message list. No pull-to-refresh here: this is a live
            // WebSocket thread (new messages arrive over the socket, not via
            // a batch reload), and there's no existing older-message
            // pagination for an overscroll-at-top gesture to trigger —
            // adding one would be new data-fetch/pagination logic, out of
            // this task's bounds. No tap-outside-dismiss either:
            // GroupMembersPanel above renders inline in the VStack flow
            // (pushing the message list down), not as a floating ZStack
            // overlay layered over other content, so it isn't the kind of
            // custom overlay this task's tap-outside-dismiss convention
            // targets.
            //
            // Applied HERE — to this VStack, before `.safeAreaInset` adds
            // the composer below — rather than to the outer ZStack as
            // before (task 20260903-message-composer-keyboard-dismiss).
            // `.safeAreaInset`'s content is laid out as a sibling to the
            // view it's chained onto, not a descendant of it, so a
            // `.simultaneousGesture` attached before `.safeAreaInset` never
            // receives touches that land inside the composer — fixing the
            // reported bug where tapping inside the composer's TextField to
            // reposition the cursor mid-text (rather than tapping outside
            // it) immediately dismissed the keyboard instead of just moving
            // the cursor. Tapping the message list / header / banners still
            // dismisses exactly as before; scroll-to-dismiss on the message
            // list (`.scrollDismissesKeyboard(.interactively)`, part of this
            // same shared modifier) is unaffected by the reordering since it
            // targets the ScrollView, which stays inside this VStack either
            // way. See AgentChatView.swift for the identical fix applied to
            // the same latent pattern there.
            .overlay(alignment: .bottom) { toastStack }
            .dismissesKeyboardOnScrollAndTap()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
            }

            // ── Sessions submenu overlay ────────────────────────────────
            // A floating ZStack layer (unlike GroupMembersPanel above,
            // which renders inline in the VStack flow) so it needs its own
            // tap-outside-dismiss rather than relying on
            // `.dismissesKeyboardOnScrollAndTap()`.
            if showSessionsMenu {
                sessionsMenuOverlay
                    .zIndex(1)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            let uid = appState.currentUser?.user_id ?? ""
            memberNames = contact.memberNames
            memberIds   = contact.toUsers
            // Task 20260913-chat-unread-badges: clearing unread state is
            // this thread actually opening, per the intake spec's recommended
            // "what counts as seen?" answer -- not merely the chat list being
            // visible or the tab being selected. Marked before `vm.load`
            // below so it isn't held up by (or racing) the message fetch --
            // opening this screen is itself the "seen" signal, regardless of
            // how the fetch that follows turns out.
            appState.markRead(contact)
            await vm.load(service: appState.service, contact: contact, userId: uid, capabilities: appState.capabilities)
            // Populates the messageGroups/threadRows cache for the first
            // render after load() -- `.onChange(of: vm.messages.count)`
            // covers every later change, but wouldn't fire for this initial
            // population if the disk-cache read and the fresh fetch happen
            // to land on the exact same count (e.g. re-opening a thread with
            // no new messages since last time).
            recomputeMessageGroups()
            // Task 20260908-chat-scroll-to-bottom-on-open: unconditional
            // initial scroll to the last row -- the reactive
            // `.onChange(of: vm.messages.count)` handler above only fires on
            // an actual count change, so it silently never ran for the
            // common "reopening a thread with nothing new since last time"
            // case, leaving the list wherever SwiftUI's ScrollView happened
            // to lay it out (a stale/prior position, not necessarily the
            // bottom). Snapped, not animated -- this is establishing the
            // thread's starting position before the screen has settled, not
            // a live "something changed while you're already looking at it"
            // moment the way a new inbound message is, so animating it would
            // visibly slide from an undefined prior position rather than
            // read as intentional motion. This just flips a plain @State
            // flag -- see its declaration above for why the actual
            // `scrollTo` call lives in `.onChange(of: readyForInitialScroll)`
            // rather than being called imperatively right here.
            readyForInitialScroll = true
            // Load the viewer's friends so the add-members picker can offer those
            // who aren't already in the group.
            if contact.type == .group {
                let (contacts, _) = (try? await appState.service.fetchContacts(userId: uid)) ?? ([], [:])
                friends = contacts.filter { $0.type == .friend }
            }
            // Task 20261001-message-threads: a thread push tap opened this
            // group chat first; now open the thread inside it.
            await consumePendingThreadOpen()
        }
        // A thread push tapped while this group's chat is already open.
        .onChange(of: appState.pendingThreadOpen) { _, _ in
            Task { await consumePendingThreadOpen() }
        }
        // thread_message send hit terms_reaccept_required: refresh capabilities,
        // which raises the existing Updated Terms gate (the typed text is
        // handed back to the composer below, never lost).
        // An empty thread focuses the composer (not under VoiceOver, where
        // focus stays on the thread title).
        .onChange(of: vm.isLoadingThread) { _, loading in
            if !loading, vm.isThreadOpen, !vm.threadLoadFailed, vm.messages.isEmpty,
               !UIAccessibility.isVoiceOverRunning {
                composerFocused = true
            }
        }
        .onChange(of: vm.termsGateSignal) { _, _ in appState.refreshCapabilities(force: true) }
        .onChange(of: vm.restoredDraft) { _, draft in
            guard let draft else { return }
            if text.isEmpty { text = draft }
            vm.restoredDraft = nil
        }
        // Resume a Start thread that was waiting on the Updated Terms gate.
        .onChange(of: appState.termsReacceptRequired) { _, required in
            if !required, let m = pendingThreadStart {
                pendingThreadStart = nil
                startThread(from: m)
            }
        }
        .onDisappear { vm.disconnect() }
        // App-lifecycle wiring (task 20260902-chat-push-notification-failure)
        // — complements onDisappear above, which only fires when this view
        // itself leaves the hierarchy, not when the whole app is backgrounded
        // while the chat thread is still the visible screen.
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                vm.handleAppBackgrounded()
            } else if phase == .active {
                vm.handleAppForegrounded()
            }
        }
        .sheet(isPresented: $showGroupInfo) {
            GroupInfoSheet(
                contact: contact,
                user: appState.currentUser,
                service: appState.service,
                memberNames: memberNames,
                photoByUsername: vm.photoByUsername,
                onTitleChanged: { groupTitleOverride = $0 },
                onPhotoChanged: { groupPhotoOverride = .some($0) },
                onAddMembers: { showAddMembers = true },
                onGroupGone: { dismiss() }
            )
            // Task 20261001-message-threads: the Threads section opens a thread
            // through this closure (it closes the sheet and switches this view
            // model into thread mode on its one socket).
            .environment(\.fsOpenThread, FSOpenThreadAction { summary in
                showGroupInfo = false
                openThread(summary)
            })
        }
        .sheet(item: $reportTarget) { target in
            ReportUserSheet(contact: target) { reason, detail in
                Task {
                    do {
                        try await appState.service.reportUser(reportedUserId: target.id, reason: reason, detail: detail)
                        showToast("Report sent. Thank you.")
                    } catch {
                        showToast((error as? LocalizedError)?.errorDescription ?? "Could not send report. Please try again.")
                    }
                }
                reportTarget = nil
            }
        }
        .confirmationDialog(
            "Block \(blockConfirmTarget?.name ?? "this user")?",
            isPresented: Binding(get: { blockConfirmTarget != nil }, set: { if !$0 { blockConfirmTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) {
                guard let target = blockConfirmTarget else { return }
                let uid = appState.currentUser?.user_id ?? ""
                blockConfirmTarget = nil
                Task {
                    do {
                        try await appState.service.blockUser(userId: uid, blockedId: target.id)
                        showToast("Blocked \(target.name).")
                    } catch {
                        showToast((error as? LocalizedError)?.errorDescription ?? "Could not block this user. Please try again.")
                    }
                }
            }
            Button("Cancel", role: .cancel) { blockConfirmTarget = nil }
        } message: {
            Text("You won't see their messages and they won't be able to message you.")
        }
        .sheet(isPresented: $showAddMembers) {
            AddGroupMembersSheet(
                candidates: friends.filter { !memberIds.contains($0.id) }
            ) { selected in
                addMembers(selected)
            }
        }
        .sheet(item: $selectedSession) { session in
            // Mirrors the old SessionBanner's own `.sheet(isPresented:)` ->
            // SessionDetailSheet wiring exactly (same onDelete/onUpdate
            // refresh), just item-driven so any row in the submenu's list
            // can be the one that opens it, not only "the next upcoming"
            // session.
            SessionDetailSheet(session: session, onDelete: refreshSessions, onUpdate: refreshSessions)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showSession) {
            SessionCreatorSheet(groupId: contact.id, onSave: { session in
                let uid = appState.currentUser?.user_id ?? ""
                // Use the shared room key so this session (and its call) is visible
                // to the other party on the web client too.
                let roomKey = ChatThreadViewModel.roomKey(contact: contact, userId: uid)
                Task {
                    do {
                        _ = try await appState.service.createSession(
                            userId: uid, devotion: session, contactId: roomKey
                        )
                    } catch {
                        // Free-plan session cap: shared upgrade prompt; other errors stay silent as before.
                        UpgradePromptCenter.shared.present(for: error)
                    }
                    vm.sessions = (try? await appState.service.fetchSessionsForContact(contactId: roomKey)) ?? vm.sessions
                }
                showSession = false
            })
        }
        .alert("Thread unavailable", isPresented: Binding(
            get: { vm.threadGoneNotice != nil },
            set: { if !$0 { vm.threadGoneNotice = nil } }
        )) {
            Button("OK", role: .cancel) { vm.threadGoneNotice = nil }
        } message: {
            Text(vm.threadGoneNotice ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: FSThreadChange.notification)) { note in
            if let c = FSThreadChange.from(note), case .renamed(let title) = c.kind,
               c.groupId.lowercased() == contact.id.lowercased() {
                vm.applyThreadRename(threadId: c.threadId, title: title)
            }
        }
        .alert("Couldn't Add Members", isPresented: Binding(
            get: { membersErrorMsg != nil },
            set: { if !$0 { membersErrorMsg = nil } }
        )) {
            Button("OK", role: .cancel) { membersErrorMsg = nil }
        } message: {
            Text(membersErrorMsg ?? "")
        }
    }

    // ── Thread mode + message actions (task 20261001-message-threads) ────────
    // Design: Alternative A (anchored native-feel menu, pinned root header),
    // provisional approval. A thread is a MODE of this view and its view model
    // (one socket): the header swaps to a persistent Back control + thread
    // title, the root message is pinned under it, and everything below
    // (grouping, scroll, older pages, composer, retry) is the unchanged chat UI.

    private func openThread(_ summary: FSThreadSummary) {
        let uid = appState.currentUser?.user_id ?? ""
        Task { await vm.openThread(summary, service: appState.service, contact: contact, userId: uid) }
    }

    /// Opens a pushed thread inside this group's chat once the chat is loaded.
    /// Waits briefly for capabilities (a cold launch from a push has none yet);
    /// with the flag still off the push just leaves the user in the chat.
    private func consumePendingThreadOpen() async {
        guard readyForInitialScroll, contact.type == .group,
              let pending = appState.pendingThreadOpen, pending.groupId == contact.id else { return }
        appState.pendingThreadOpen = nil
        var waited = 0
        while !appState.capabilities.isEnabled("threads") && waited < 10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 1
        }
        guard appState.capabilities.isEnabled("threads") else { return }
        let uid = appState.currentUser?.user_id ?? ""
        await vm.openThread(id: pending.threadId, service: appState.service, contact: contact, userId: uid)
    }

    private func rowActions(for message: FSMessage) -> [MessageRowAction] {
        let caps = appState.capabilities
        let ctx = FSMessageActionContext(
            isGroup: contact.type == .group,
            inThread: vm.isThreadOpen,
            threadsEnabled: caps.isEnabled("threads"),
            messageDeleteEnabled: caps.isEnabled("message_delete"),
            isSettled: vm.isSettled(message),
            senderUserId: vm.senderUserId(for: message)
        )
        return FSMessageActionPolicy.actions(for: message, in: ctx).map { kind in
            MessageRowAction(kind: kind) { performAction(kind, on: message) }
        }
    }

    private func performAction(_ kind: FSMessageActionKind, on message: FSMessage) {
        switch kind {
        case .copy:
            if let text = message.copyableText {
                UIPasteboard.general.string = text
                showToast("Copied", seconds: 1.5)
            }
        case .startThread:
            startThread(from: message)
        case .delete:
            deleteMessage(message)
        case .report:
            if let id = vm.senderUserId(for: message) {
                reportTarget = FSContact(id: id, name: message.sender, type: .friend)
            }
        case .block:
            if let id = vm.senderUserId(for: message) {
                blockConfirmTarget = FSContact(id: id, name: message.sender, type: .friend)
            }
        }
    }

    private func startThread(from message: FSMessage) {
        let uid = appState.currentUser?.user_id ?? ""
        Task {
            do {
                try await vm.startThread(from: message, service: appState.service, contact: contact, userId: uid)
            } catch let error as FSThreadsError {
                switch error {
                case .termsReacceptRequired:
                    // Existing Updated Terms gate; the create resumes once accepted.
                    pendingThreadStart = message
                    appState.refreshCapabilities(force: true)
                    showToast("Accept the updated Terms to start a thread.", seconds: 4)
                case .threadLimit:
                    showToast(error.errorDescription ?? "This group has reached its thread limit.", seconds: 4)
                case .notFound:
                    showToast("Couldn't start a thread on that message.", seconds: 4)
                case .failed(let m):
                    showToast(m, seconds: 4)
                }
            } catch {
                showToast("Couldn't start a thread on that message.", seconds: 4)
            }
        }
    }

    /// Optimistic delete with a 10 s (server `undo_seconds`) Undo toast; no
    /// confirmation dialog (undo-after-the-fact).
    private func deleteMessage(_ message: FSMessage) {
        let uid = appState.currentUser?.user_id ?? ""
        Task {
            do {
                let result = try await vm.deleteOwnMessage(message, service: appState.service, contact: contact, userId: uid)
                showToast("Message deleted", seconds: Double(max(result.undoSeconds, 1)), undoTitle: "Undo") {
                    Task {
                        do {
                            try await vm.undoDelete(message, service: appState.service, contact: contact, userId: uid)
                        } catch {
                            showToast("Couldn't undo that delete.", seconds: 4)
                        }
                    }
                }
            } catch {
                showToast("Couldn't delete that message. Please try again.", seconds: 4)
            }
        }
    }

    private func showToast(_ message: String, seconds: Double = 2.5, undoTitle: String? = nil, undo: (() -> Void)? = nil) {
        let toast = ChatToast(message: message, seconds: seconds, undoTitle: undoTitle, undo: undo)
        withMotionAwareAnimation(.easeOut(duration: 0.18), reduceMotion: reduceMotion) {
            toasts.append(toast)
        }
        let spoken = undoTitle == nil ? message : "\(message). \(undoTitle ?? "") available for \(Int(seconds)) seconds"
        UIAccessibility.post(notification: .announcement, argument: spoken)
    }

    private func dismissToast(_ id: UUID) {
        withMotionAwareAnimation(.easeIn(duration: 0.12), reduceMotion: reduceMotion) {
            toasts.removeAll { $0.id == id }
        }
    }

    private var toastStack: some View {
        VStack(spacing: 8) {
            ForEach(toasts) { toast in
                ChatToastRow(toast: toast, onDismiss: { dismissToast(toast.id) })
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.bottom, Theme.spacingSM)
    }

    /// Back control (labelled with the group name) + thread title + group name.
    private var threadHeader: some View {
        HStack(spacing: 14) {
            RoundIconButton(systemIcon: "chevron.left") {
                withMotionAwareAnimation(.easeOut(duration: 0.18), reduceMotion: reduceMotion) { vm.closeThread() }
            }
            .accessibilityLabel("Back to \(displayName)")

            VStack(alignment: .leading, spacing: 2) {
                Text(vm.activeThread?.title ?? "Thread")
                    .font(.inter(Theme.fontHeading, weight: .bold))
                    .foregroundColor(Theme.parchment)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($threadTitleFocused)
                Text(displayName)
                    .font(.inter(Theme.fontXS))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.top, Theme.spacingSM)
        .padding(.bottom, Theme.spacingSM)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.borderGoldFaint).frame(height: 1)
        }
    }

    /// Pinned root message. A deleted root shows "Original message deleted";
    /// the thread stays usable. Hidden when the root text is unknown (a
    /// pushed thread not found in the list).
    @ViewBuilder
    private var threadRootCard: some View {
        if let t = vm.activeThread, t.rootDeleted || !t.rootPreview.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Thread")
                    .font(.inter(Theme.fontXXS, weight: .semibold))
                    .foregroundColor(Theme.gold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Theme.gold.opacity(0.15))
                    .clipShape(Capsule())
                Text(t.rootDeleted ? "Original message deleted" : t.rootPreview)
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(t.rootDeleted ? Theme.textSecondary : Theme.parchment)
                    .italic(t.rootDeleted)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.spacingSM)
            .background(Color.white.opacity(0.045))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderGoldFaint, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .padding(.horizontal, Theme.spacingMD)
            .padding(.top, Theme.spacingSM)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(t.rootDeleted ? "Thread root: original message deleted" : "Thread root: \(t.rootPreview)")
        }
    }

    /// Loading / error+Retry / empty states of the open thread (top of the list).
    @ViewBuilder
    private var threadStateView: some View {
        if vm.isThreadOpen {
            if vm.threadLoadFailed {
                VStack(spacing: 6) {
                    Text("Couldn't load this thread.")
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.error)
                    Button("Retry") {
                        let uid = appState.currentUser?.user_id ?? ""
                        Task { await vm.loadThreadFirstPage(service: appState.service, contact: contact, userId: uid) }
                    }
                    .font(.inter(Theme.fontXS, weight: .semibold)).foregroundColor(Theme.gold)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint("Reloads this thread")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.spacingSM)
            } else if vm.isLoadingThread && vm.messages.isEmpty {
                HStack(spacing: 6) {
                    if !reduceMotion { ProgressView().tint(Theme.gold).scaleEffect(0.75) }
                    Text("Loading thread…")
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.textGoldMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.spacingSM)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading thread")
            } else if vm.messages.isEmpty {
                Text("Start the conversation")
                    .font(.inter(Theme.fontSM)).foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.spacingLG)
                    .accessibilityLabel("No replies yet. Start the conversation")
            }
        }
    }

    // ── Header: back · avatar/name (tap to toggle members) · "Schedule" pill ──
    // Custom in-body header (mirrors ChatRootView.swift's own header
    // convention) instead of the native NavigationStack toolbar, so this
    // screen can share the exact same visual language (round icon button,
    // serif identity label, amber-gradient pill) as the rest of the restyled
    // Chat surfaces.
    private var displayName: String { groupTitleOverride ?? contact.name }
    private var displayPhotoURL: String? {
        if let override = groupPhotoOverride { return override }
        return contact.photoUrl
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundIconButton(systemIcon: "chevron.left") { dismiss() }
                .accessibilityLabel("Go back")

            Button(action: {
                if contact.type == .group { showGroupInfo = true }
            }) {
                HStack(spacing: 12) {
                    // Task 20260905-profile-photo-avatar-gaps: `contact.photoUrl`
                    // is already populated for a friend DM (NetworkService+
                    // Contacts.swift's fetchContacts) and correctly nil for a
                    // group (no single identity to show here) -- it was simply
                    // unused by this header before this fix.
                    AvatarView(
                        initial: String(displayName.prefix(1)).uppercased(),
                        photoURL: displayPhotoURL,
                        diameter: 38,
                        fillColor: Theme.gold.opacity(0.18),
                        textColor: Theme.gold
                    )
                    .overlay(Circle().stroke(Theme.borderGoldDim, lineWidth: 1))

                    HStack(spacing: 5) {
                        Text(displayName)
                            .font(.inter(Theme.fontHeading, weight: .bold))
                            .foregroundColor(Theme.parchment)
                            .lineLimit(1)
                        if contact.type == .group {
                            Image(systemName: "person.3.fill")
                                .font(.caption2)
                                .foregroundColor(Theme.gold.opacity(0.55))
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(contact.type == .group ? "Group info, \(displayName)" : contact.name)
            .accessibilityHint(contact.type == .group ? "Opens group settings, members, and shared media" : "")

            Spacer(minLength: 8)

            PillButton(title: "Sessions", systemIcon: "calendar") {
                openSessionsMenu()
            }
            .accessibilityLabel("View and schedule study sessions")
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.top, Theme.spacingSM)
        .padding(.bottom, Theme.spacingSM)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.borderGoldFaint).frame(height: 1)
        }
    }

    // ── Sessions submenu (task 20260920-chat-sessions-submenu) ────────────────
    // Replaces the old inline SessionBanner card: tapping the header's
    // "Sessions" pill opens this floating panel over a translucent, blurred
    // scrim rather than a modal `.sheet` -- keeping the chat thread visible
    // (dimmed) behind it reads as a lightweight submenu, matching the
    // request, rather than a full context switch away from the thread.

    private func openSessionsMenu() {
        withMotionAwareAnimation(.spring(response: 0.35, dampingFraction: 0.82), reduceMotion: reduceMotion) {
            showSessionsMenu = true
        }
    }

    private func closeSessionsMenu() {
        withMotionAwareAnimation(.easeOut(duration: 0.18), reduceMotion: reduceMotion) {
            showSessionsMenu = false
        }
    }

    // `fetch_by_contact` (api/backend/interactions/devotion.py) returns
    // devotions straight from a dict lookup with no `ORDER BY` on
    // time_start -- so `vm.sessions`' own array order was never actually
    // guaranteed to be "next upcoming first," it just happened to work for
    // the old `.first`-only banner. That assumption doesn't survive showing
    // every session in one list, so this sorts client-side instead: upcoming
    // sessions soonest-first, past sessions most-recent-first, so what's
    // coming up next stays at the top regardless of backend ordering.
    //
    // Task 20260921-recurring-session-next-occurrence (frontend step 3):
    // confirmed these are plain computed properties re-evaluated from
    // `vm.sessions` on every render, not values memoized once at fetch
    // time -- so once scheduler.py's `_advance_recurring_sessions` job
    // rolls a recurring session's `time_start`/`time_end` forward a week
    // and the client re-fetches (see `handleAppForegrounded()` above for
    // which paths that covers today), the advanced row falls out of
    // `pastSessions` and into `upcomingSessions` automatically, with no
    // additional client-side recurrence math needed here.
    private var upcomingSessions: [FSSession] {
        let now = Date()
        return vm.sessions
            .filter { (parseFlexibleISO8601($0.time_start) ?? .distantPast) >= now }
            .sorted { (parseFlexibleISO8601($0.time_start) ?? .distantPast) < (parseFlexibleISO8601($1.time_start) ?? .distantPast) }
    }

    private var pastSessions: [FSSession] {
        let now = Date()
        return vm.sessions
            .filter { (parseFlexibleISO8601($0.time_start) ?? .distantPast) < now }
            .sorted { (parseFlexibleISO8601($0.time_start) ?? .distantPast) > (parseFlexibleISO8601($1.time_start) ?? .distantPast) }
    }

    private var sessionsMenuOverlay: some View {
        ZStack {
            // Task 20260920-sessions-menu-background-blur: this used to be a
            // full-screen `.ultraThinMaterial` fill, which blurred/dimmed the
            // entire chat thread behind the card instead of just sitting
            // behind it. Swapped for an invisible tap-catcher -- the thread
            // stays fully visible, and `sessionsMenuCard` below already
            // supplies its own `.regularMaterial` translucency, so the
            // glassmorphism treatment still reads on the card itself.
            // `.contentShape(Rectangle())` keeps the whole screen tappable
            // for dismiss even though `Color.clear` has no fill to hit-test
            // against on its own.
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { closeSessionsMenu() }
                .accessibilityLabel("Close sessions menu")
                .accessibilityAddTraits(.isButton)

            VStack {
                sessionsMenuCard
                    .padding(.horizontal, Theme.spacingMD)
                Spacer()
            }
            .padding(.top, 76) // clears the header row so the card reads as anchored under the "Sessions" pill
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity),
                    removal: .opacity
                )
        )
    }

    private var sessionsMenuCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            HStack {
                Text("Sessions")
                    .font(.inter(Theme.fontSM, weight: .bold))
                    .foregroundColor(Theme.parchment)
                Spacer()
                Button {
                    closeSessionsMenu()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.textGoldMuted)
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            Button {
                closeSessionsMenu()
                showSession = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Schedule new session")
                        .font(.inter(Theme.fontSM, weight: .bold))
                }
                .foregroundColor(Theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Theme.goldGradient)
                .clipShape(Capsule())
                .topEdgeHighlight(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Schedule a new session")

            Rectangle().fill(Theme.borderGoldFaint).frame(height: 1)

            if vm.sessions.isEmpty {
                // Empty state kept minimal/on-brand per preference profile
                // rather than an invented illustrated treatment -- still
                // surfaces the schedule action above.
                Text("No sessions scheduled yet.")
                    .font(.inter(Theme.fontXS))
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Theme.spacingSM)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if !upcomingSessions.isEmpty {
                            if !pastSessions.isEmpty {
                                SectionEyebrow(title: "Upcoming")
                                    .padding(.top, Theme.spacingXS)
                            }
                            ForEach(upcomingSessions) { session in
                                sessionRow(session)
                            }
                        }
                        if !pastSessions.isEmpty {
                            if !upcomingSessions.isEmpty {
                                SectionEyebrow(title: "Past")
                                    .padding(.top, Theme.spacingXS)
                            }
                            ForEach(pastSessions) { session in
                                sessionRow(session)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(Theme.spacingMD)
        .frame(width: 300)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXL))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusXL).stroke(Theme.borderGoldDim, lineWidth: 1))
        .topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusXL))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func sessionRow(_ session: FSSession) -> some View {
        Button {
            selectedSession = session
            closeSessionsMenu()
        } label: {
            HStack(spacing: Theme.spacingSM) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.gold)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .font(.inter(Theme.fontXS, weight: .semibold))
                        .foregroundColor(Theme.parchment)
                        .lineLimit(1)
                    Text(session.formattedStart)
                        .font(.inter(Theme.fontXXS))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textGoldMuted.opacity(0.6))
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View session details: \(session.title), \(session.formattedStart)")
    }

    // ── Composer (mirrors chat.html's flush full-width `.input-bar`) ──────────
    // Task 20260904-messaging-attachments (design gate §1/§3): adds the
    // attach affordance and the staged (pre-send) attachment preview chip
    // directly above the text field — everything else about the composer is
    // unchanged.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let staged = stagedAttachment {
                StagedAttachmentChipView(
                    attachment: staged,
                    onRemove: {
                        stagedAttachment = nil
                        stagedUploadState = nil
                        attachmentErrorMsg = nil
                    },
                    onRetry: { startUpload(staged) }
                )
            }
            if let attachmentErrorMsg {
                Text(attachmentErrorMsg)
                    .font(.inter(Theme.fontXS))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.top, Theme.spacingXS)
            }
            // Task 20260904-attach-picker-layout-polish: renders directly
            // above the text field in a single horizontal row instead of a
            // from-the-bottom `.sheet` — see AttachPickerRow's doc comment.
            if showAttachSheet {
                AttachPickerRow(
                    onPickPhotoVideo: { showAttachSheet = false; showPhotoVideoPicker = true },
                    onPickFile:       { showAttachSheet = false; showDocumentPicker = true },
                    onPickGif:        { showAttachSheet = false; showGifSheet = true }
                )
            }
            HStack(spacing: 10) {
                attachButton

                TextField("", text: $text,
                          prompt: Text(vm.isThreadOpen ? "Reply in thread…" : "Type a message…").foregroundColor(Theme.textSecondary), axis: .vertical)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .lineLimit(1...4)
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.vertical, Theme.spacingSM)
                    .background(Color.white.opacity(0.05))
                    .overlay(Capsule().stroke(Theme.borderGoldDim, lineWidth: 1))
                    .clipShape(Capsule())
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit(sendMessage)
                    .accessibilityLabel("Message input field")

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Theme.ink)
                        .frame(width: 38, height: 38)
                        .background(canSend ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Theme.gold.opacity(0.35)))
                        .clipShape(Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Send message")
            }
            .padding(.horizontal, Theme.spacingMD)
            .padding(.top, Theme.spacingSM)
            .padding(.bottom, Theme.spacingMD)
        }
        .background(Theme.bgPage.opacity(0.55))
        .sheet(isPresented: $showPhotoVideoPicker) {
            PhotoVideoPicker(
                onPicked: { attachment in handlePicked(attachment) },
                onFailure: { attachmentErrorMsg = "Couldn't load that attachment. Please try again." }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker(
                onPicked: { attachment in handlePicked(attachment) },
                onFailure: { attachmentErrorMsg = "Couldn't load that file. Please try again." }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showGifSheet) {
            GifSearchSheet(service: appState.service) { attachment in
                attachmentErrorMsg = nil
                stagedAttachment = attachment
                stagedUploadState = attachment.uploadState
            }
        }
    }

    // 44pt tap target over a visually-36pt glyph (design gate §1) — the
    // composer's pre-existing send button (38pt) is a known, out-of-scope-
    // to-retrofit-here undersized precedent; the new attach control doesn't
    // inherit it.
    private var attachButton: some View {
        Button(action: { showAttachSheet.toggle() }) {
            Image(systemName: "plus")
                .font(.system(size: 36 * 0.4, weight: .semibold))
                .foregroundColor(Theme.gold)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.05))
                .overlay(Circle().stroke(Theme.borderGoldDim, lineWidth: 1))
                .clipShape(Circle())
                .topEdgeHighlight(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .accessibilityLabel("Attach a photo, video, file, or GIF")
    }

    // Matches "send is otherwise disabled only when there is neither text nor
    // a staged attachment" (design gate §3), plus: stays disabled while an
    // image/video/file upload is in flight or has failed (the one genuinely
    // ambiguous state this feature adds), enabling once uploaded or
    // immediately for a staged GIF (nothing of ours to upload).
    private var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard stagedAttachment != nil else { return hasText }
        // Reads `stagedUploadState` (a plain @State mirror kept in sync by
        // startUpload below), not `stagedAttachment?.uploadState` directly
        // -- see `stagedUploadState`'s declaration for why.
        switch stagedUploadState {
        case .uploading, .failed, .none: return false
        case .idle, .uploaded:           return true
        }
    }

    private func handlePicked(_ attachment: StagedAttachment?) {
        guard let attachment else { return }
        if let sizeError = oversizeError(for: attachment) {
            attachmentErrorMsg = sizeError
            return
        }
        attachmentErrorMsg = nil
        stagedAttachment = attachment
        stagedUploadState = attachment.uploadState
        if attachment.kind != .gif {
            startUpload(attachment)
        }
    }

    /// Advisory client-side check before even requesting an upload URL
    /// (design gate §3) — real enforcement is the presigned POST policy's
    /// content-length-range condition (security step 1), not this. Phrased
    /// from security step 1's actual concrete per-kind limits.
    private func oversizeError(for attachment: StagedAttachment) -> String? {
        guard let data = attachment.fileData else { return nil }
        let maxBytes: Int
        switch attachment.kind {
        case .image: maxBytes = 15  * 1024 * 1024
        case .video: maxBytes = 250 * 1024 * 1024
        case .file:  maxBytes = 50  * 1024 * 1024
        case .gif:   return nil
        }
        guard data.count <= maxBytes else {
            return AttachmentErrorCopy.forOversize(kind: attachment.kind)
        }
        return nil
    }

    private func startUpload(_ attachment: StagedAttachment) {
        attachment.uploadState = .uploading
        stagedUploadState = .uploading
        guard let data = attachment.fileData else {
            attachment.uploadState = .failed
            stagedUploadState = .failed
            return
        }
        let uid = appState.currentUser?.user_id ?? ""
        Task {
            do {
                let info = try await appState.service.requestAttachmentUploadURL(
                    userId: uid, attachmentKind: attachment.kind.rawValue,
                    contentType: attachment.contentType, sizeBytes: data.count
                )
                try await appState.service.uploadAttachment(
                    fileData: data, contentType: attachment.contentType, uploadInfo: info
                )
                await MainActor.run {
                    let resolved = StagedAttachmentUploadState.uploaded(objectKey: info.object_key)
                    attachment.uploadState = resolved
                    // Guard against a stale completion landing after the
                    // user removed/replaced this attachment mid-upload --
                    // only mirror into the view's own @State if this is
                    // still the currently staged attachment.
                    if stagedAttachment === attachment { stagedUploadState = resolved }
                }
            } catch {
                // Manual tap-to-retry only, no automatic retry loop (design
                // gate §3 / intake's explicit "not required for v1").
                await MainActor.run {
                    attachment.uploadState = .failed
                    if stagedAttachment === attachment { stagedUploadState = .failed }
                }
            }
        }
    }

    private func sendMessage() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, (!trimmed.isEmpty || stagedAttachment != nil) else { return }
        let uid = appState.currentUser?.user_id ?? ""
        vm.sendMessage(text: trimmed, attachment: stagedAttachment, contact: contact, userId: uid)
        text = ""
        stagedAttachment = nil
        stagedUploadState = nil
        attachmentErrorMsg = nil
    }

    private func addMembers(_ selected: [FSContact]) {
        guard !selected.isEmpty else { return }
        let uid = appState.currentUser?.user_id ?? ""
        // Snapshot before the optimistic mutation so a failed write can be
        // rolled back instead of leaving the client and server member lists
        // silently out of sync (backend step 8 finding #1).
        let previousIds   = memberIds
        let previousNames = memberNames
        // Optimistically reflect the new members in the panel.
        memberIds.append(contentsOf: selected.map { $0.id })
        memberNames.append(contentsOf: selected.map { $0.name })
        let updatedUsers = memberIds
        Task {
            do {
                try await appState.service.updateGroup(
                    userId: uid, groupId: contact.id, title: contact.name, users: updatedUsers
                )
            } catch {
                // updateGroup now uses checkedRequestRaw, so a rejected write
                // (expired session, or the group_router content-filter 422 on
                // the title) throws instead of silently no-opping. Roll back
                // the optimistic mutation and tell the user why.
                memberIds   = previousIds
                memberNames = previousNames
                membersErrorMsg = (error as? LocalizedError)?.errorDescription ?? "Could not add members."
            }
        }
    }

    // Shared by SessionBanner's onDelete and onUpdate (task
    // 20260914-session-edit-button) -- both mutations just need the
    // session list re-fetched from the server afterward, so this replaces
    // what used to be a copy of this same fetch inlined at the onDelete
    // call site alone.
    private func refreshSessions() {
        let uid = appState.currentUser?.user_id ?? ""
        let key = ChatThreadViewModel.roomKey(contact: contact, userId: uid)
        Task {
            vm.sessions = (try? await appState.service.fetchSessionsForContact(contactId: key)) ?? []
        }
    }
}

// ── Group members panel (mirrors ChatView showMembers block) ──────────────────
struct GroupMembersPanel: View {
    let memberNames: [String]       // usernames, excluding the current user
    let user:        FSUser?
    // Task 20260905-profile-photo-avatar-gaps: username → photo URL for
    // every *other* member, reusing the exact lookup ChatThreadViewModel
    // already builds for MessageGroupRow's bubble avatars
    // (`vm.photoByUsername`, populated by `resolveGroupMemberPhotos()`) --
    // no new fetch. Defaulted so this stays source-compatible with any
    // existing call site/preview/test that predates this field, falling
    // back to the initials-only treatment exactly as before.
    var photoByUsername: [String: String] = [:]
    var onAddTapped: (() -> Void)?  // present when the viewer may add members

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text("Members")
                .font(.inter(Theme.fontXXS)).tracking(3).textCase(.uppercase)
                .foregroundColor(Theme.gold.opacity(0.70))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.spacingSM) {
                    avatarChip(name: user?.username ?? "You", isMe: true, photoURL: user?.profile_photo_url)
                    ForEach(Array(memberNames.prefix(20).enumerated()), id: \.offset) { _, name in
                        avatarChip(name: name.isEmpty ? "Member" : name, isMe: false, photoURL: photoByUsername[name])
                    }
                    if let onAddTapped {
                        addChip(action: onAddTapped)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.spacingSM)
        .padding(.vertical, Theme.spacingMD)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider().background(Theme.borderGoldFaint) }
    }

    @ViewBuilder
    private func avatarChip(name: String, isMe: Bool, photoURL: String? = nil) -> some View {
        HStack(spacing: 4) {
            AvatarView(
                initial: String(name.prefix(1)).uppercased(),
                photoURL: photoURL,
                diameter: 26,
                fillColor: Theme.gold.opacity(0.12),
                textColor: Theme.gold
            )
            Text(isMe ? "\(name) (you)" : name)
                .font(.inter(Theme.fontXS))
                .foregroundColor(isMe ? Theme.gold : Theme.parchment.opacity(0.70))
        }
        .accessibilityLabel(isMe ? "\(name), you" : name)
    }

    // Subtle dashed "+" chip that sits at the end of the member row.
    @ViewBuilder
    private func addChip(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            Theme.gold.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1, dash: [3])
                        )
                        .frame(width: 26, height: 26)
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.gold)
                }
                Text("Add")
                    .font(.inter(Theme.fontXS))
                    .foregroundColor(Theme.gold.opacity(0.75))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add friends to group")
    }
}

// ── Add-members sheet (friend picker for an existing group) ───────────────────
struct AddGroupMembersSheet: View {
    let candidates: [FSContact]        // friends not already in the group
    let onAdd:      ([FSContact]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIds = Set<String>()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()

                if candidates.isEmpty {
                    VStack(spacing: Theme.spacingMD) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 36, weight: .light))
                            .foregroundColor(Theme.gold.opacity(0.35))
                        Text("All your friends are already in this group.")
                            .font(.inter(Theme.fontSM))
                            .foregroundColor(Theme.textMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Theme.spacingXL)
                    }
                } else {
                    Form {
                        Section("Add friends") {
                            ForEach(candidates) { f in
                                HStack {
                                    Text(f.name)
                                        .font(.inter(Theme.fontBody))
                                        .foregroundColor(Theme.parchment.opacity(0.70))
                                    Spacer()
                                    if selectedIds.contains(f.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(Theme.gold)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if selectedIds.contains(f.id) { selectedIds.remove(f.id) }
                                    else                           { selectedIds.insert(f.id) }
                                }
                                .accessibilityLabel("\(f.name). \(selectedIds.contains(f.id) ? "Selected" : "Not selected")")
                                .accessibilityAddTraits(selectedIds.contains(f.id) ? .isSelected : [])
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Theme.bgPage)
                }
            }
            .navigationTitle("Add Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(Theme.textGoldMuted)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        onAdd(candidates.filter { selectedIds.contains($0.id) })
                        dismiss()
                    }
                    .foregroundColor(Theme.gold)
                    .disabled(selectedIds.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// ── Session banner (mirrors SessionWidget.jsx) ────────────────────────────────
struct SessionBanner: View {
    let session: FSSession
    var onDelete: (() -> Void)? = nil
    // Task 20260914-session-edit-button: fired after a successful edit save,
    // mirroring onDelete above so the caller can refresh its session list the
    // same way for either mutation.
    var onUpdate: (() -> Void)? = nil
    @EnvironmentObject var appState: AppState
    @State private var showDetail = false

    var body: some View {
        // Decision 1 (design step 1, fidelity pass): split into an outer
        // VStack — row 1 keeps the icon/title/time, row 2 is a new
        // full-width Join+Details row below it — instead of one shared
        // HStack. The original single-HStack skeleton starved the button
        // row for width, causing "Join"'s label to text-wrap ("Jo"/"in")
        // at realistic session-title lengths ("Wednesday Night Study"),
        // and didn't match render-3-session-summary.png's two-row layout,
        // which the original Ember Glass design gate never actually
        // decided (it only addressed elevation §1 and the icon bloom §11).
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            HStack(spacing: Theme.spacingMD) {
                ZStack {
                    Circle().fill(Theme.gold.opacity(0.16))
                    Circle().stroke(Theme.borderGoldDim, lineWidth: 1)
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Theme.gold)
                }
                .frame(width: 40, height: 40)
                // Added item 1: focal ambient bloom behind the calendar badge
                // (design gate §11, visible in render-3-session-summary.png as a
                // warm halo around the icon). Background sizing keeps the halo
                // from being clipped to the badge's own 40x40 frame.
                .background(
                    RadialGradient(colors: [Theme.gold.opacity(0.35), .clear],
                                   center: .center, startRadius: 2, endRadius: 40)
                        .frame(width: 100, height: 100)
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.inter(Theme.fontSM, weight: .bold))
                        .foregroundColor(Theme.parchment)
                    Text(session.formattedStart)
                        .font(.inter(Theme.fontXS))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
            }

            // Row 2 (design decision 1): a distinct, full-width Join+Details
            // row below the title/time — not indented under the text — each
            // button given .frame(maxWidth: .infinity) so together they span
            // most of the card's content width, matching render-3. This also
            // structurally resolves the Join-label wrap: with the row no
            // longer sharing space with the title, "Join" has no plausible
            // remaining wrap scenario at realistic title lengths (verified
            // directly — see EmberGlassChatRegressionTests).
            HStack(spacing: Theme.spacingSM) {
                // Join call button — starts/joins the persistent call. Kept
                // green (established call-affordance convention elsewhere in
                // the app) — only the shape/typography is restyled, per the
                // migration's "styling only, not the call screen" scope.
                //
                // Task 20260920-session-join-window-gating: greyed out/
                // untappable outside the session's opening window
                // (join-window-contract.md §6). `TimelineView` re-evaluates
                // `session.isJoinWindowOpen` on a 1s cadence so the state
                // flips live while this card stays on screen, rather than
                // only once at `body` evaluation time.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let canJoin = session.isJoinWindowOpen(now: context.date)
                    Button {
                        CallController.shared.start(session: session,
                                                    service: appState.service,
                                                    userId: appState.currentUser?.user_id ?? "")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "video.fill")
                                .font(.system(size: 11))
                            Text("Join")
                                .font(.system(size: 12, weight: .bold))
                                .fixedSize()
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        // Same reduced-opacity-on-same-hue disabled treatment
                        // already used elsewhere in this file (e.g. the
                        // composer's send button) rather than inventing a new
                        // disabled-state convention.
                        .background(Theme.success.opacity(canJoin ? 0.82 : 0.35))
                        .clipShape(Capsule())
                    }
                    .disabled(!canJoin)
                    // Per UI/UX Q10/Q17: the greyed state alone is sufficient
                    // feedback -- no confirmation dialog, no extra copy.
                    .accessibilityLabel(canJoin
                        ? "Join call for \(session.title)"
                        : "Join call for \(session.title), not open yet")
                }

                Button {
                    showDetail = true
                } label: {
                    Text("Details")
                        .fixedSize()
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.gold)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Theme.spacingSM)
                        .padding(.vertical, 7)
                        .overlay(Capsule().stroke(Theme.borderGold, lineWidth: 1))
                }
                .accessibilityLabel("View session details: \(session.title)")
            }
        }
        .padding(Theme.spacingMD)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXL))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusXL).stroke(Theme.borderGoldDim, lineWidth: 1))
        .topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusXL))
        .sheet(isPresented: $showDetail) {
            SessionDetailSheet(session: session, onDelete: onDelete, onUpdate: onUpdate)
                .environmentObject(appState)
        }
    }
}

// ── Session detail sheet ──────────────────────────────────────────────────────
struct SessionDetailSheet: View {
    let session: FSSession
    var onDelete: (() -> Void)? = nil
    // Task 20260914-session-edit-button: fired after a successful edit save
    // so the caller can refresh its session list, mirroring onDelete.
    var onUpdate: (() -> Void)? = nil
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var showEditSheet = false

    // Only the user who created the session may edit or delete it. `internal`
    // (not `private`), matching NoteDetailView.canEdit's testability-seam
    // convention, so a gate test can assert on it directly via @testable
    // import rather than driving a full render.
    internal var isHost: Bool {
        !session.creator_id.isEmpty && session.creator_id == appState.currentUser?.user_id
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPage.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.spacingLG) {
                        // Join call CTA — start the persistent call, then close
                        // this sheet so the call takes over full-screen.
                        //
                        // Task 20260920-session-join-window-gating: greyed
                        // out/untappable outside the session's opening window
                        // (join-window-contract.md §6), live-updating via
                        // `TimelineView` on the same 1s cadence as
                        // SessionBanner's own Join button above.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let canJoin = session.isJoinWindowOpen(now: context.date)
                            Button {
                                CallController.shared.start(session: session,
                                                            service: appState.service,
                                                            userId: appState.currentUser?.user_id ?? "")
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "video.fill")
                                        .font(.system(size: 16))
                                    Text("Join Audio & Video Call")
                                        .font(.inter(Theme.fontBody, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.success.opacity(canJoin ? 0.82 : 0.35))
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXL))
                            }
                            .disabled(!canJoin)
                            .accessibilityLabel(canJoin
                                ? "Join audio and video call for \(session.title)"
                                : "Join audio and video call for \(session.title), not open yet")
                        }

                        VStack(alignment: .leading, spacing: Theme.spacingXS) {
                            SectionEyebrow(title: "Study Session")
                            Text(session.title)
                                .font(.playfair(Theme.fontDisplayMD))
                                .foregroundColor(Theme.parchment)
                            Text(session.formattedStart)
                                .font(.inter(Theme.fontSM))
                                .foregroundColor(Theme.textGoldMuted)
                        }

                        if !session.verses.isEmpty {
                            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                                SectionEyebrow(title: "Verses")
                                ForEach(session.verses, id: \.self) { ref in
                                    Text(ref.replacingOccurrences(of: "-", with: " "))
                                        .font(.verseRef(Theme.fontBody))
                                        .foregroundColor(Theme.gold)
                                }
                            }
                        }

                        if !session.prompts.isEmpty {
                            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                                SectionEyebrow(title: "Discussion Prompts")
                                ForEach(Array(session.prompts.enumerated()), id: \.offset) { i, p in
                                    HStack(alignment: .top, spacing: Theme.spacingSM) {
                                        Text("\(i+1).")
                                            .font(.inter(Theme.fontSM))
                                            .foregroundColor(Theme.gold)
                                        Text(p)
                                            .font(.inter(Theme.fontSM))
                                            .foregroundColor(Theme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }

                        if session.recurring {
                            Label("Repeats weekly", systemImage: "repeat")
                                .font(.inter(Theme.fontSM))
                                .foregroundColor(Theme.textGoldMuted)
                        }

                        // Host-only: edit or delete the session they created.
                        // Stacked (not paired side-by-side) so Delete keeps
                        // its full-width destructive weight rather than
                        // sharing a row with a same-size non-destructive
                        // action, consistent with this sheet's existing
                        // full-width single-action button style above.
                        if isHost {
                            VStack(spacing: Theme.spacingSM) {
                                Button { showEditSheet = true } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "pencil")
                                        Text("Edit Session")
                                            .font(.inter(Theme.fontBody, weight: .semibold))
                                    }
                                    .foregroundColor(Theme.gold)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Theme.gold.opacity(0.10))
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                                    .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                                        .stroke(Theme.borderGold, lineWidth: 1))
                                }
                                .accessibilityLabel("Edit session \(session.title)")

                                Button(role: .destructive) { showDeleteConfirm = true } label: {
                                    HStack(spacing: 8) {
                                        if isDeleting {
                                            ProgressView().tint(Theme.error)
                                        } else {
                                            Image(systemName: "trash")
                                            Text("Delete Session")
                                                .font(.inter(Theme.fontBody, weight: .semibold))
                                        }
                                    }
                                    .foregroundColor(Theme.error)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Theme.error.opacity(0.10))
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                                    .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                                        .stroke(Theme.error.opacity(0.35), lineWidth: 1))
                                }
                                .disabled(isDeleting)
                                .accessibilityLabel("Delete session \(session.title)")
                            }
                            .padding(.top, Theme.spacingSM)
                        }
                    }
                    .padding(Theme.spacingLG)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(Theme.gold)
                }
            }
            .alert("Delete Session?", isPresented: $showDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { deleteSession() }
            } message: {
                Text("This permanently deletes \"\(session.title)\" for everyone. This can't be undone.")
            }
            .sheet(isPresented: $showEditSheet) {
                SessionCreatorSheet(
                    groupId: session.group_id,
                    existingSession: session,
                    onSaveAsync: { updated in
                        let uid = appState.currentUser?.user_id ?? ""
                        try await appState.service.updateSession(
                            userId: uid, sessionId: session.id, devotion: updated
                        )
                        await MainActor.run { onUpdate?() }
                    }
                )
            }
        }
        .preferredColorScheme(.dark)
    }

    private func deleteSession() {
        let uid = appState.currentUser?.user_id ?? ""
        isDeleting = true
        Task {
            try? await appState.service.deleteSession(
                userId: uid, sessionId: session.id, devotion: session
            )
            await MainActor.run {
                isDeleting = false
                onDelete?()   // let the thread refresh its session list
                dismiss()
            }
        }
    }
}

// ── Session creator sheet (mirrors SessionCreator.jsx fields / schedule.html) ─
// Bottom-sheet presentation restyle: drag handle, Cancel/title/"Schedule"
// pill header row, segmented 15/30/45/60m duration control, chip-style
// option toggles. `duration` is UI-only — FSSession has no duration field —
// time_end is computed from time_start + duration.rawValue minutes when
// building the FSSession to hand to onSave (unchanged create path: the
// caller in ChatThreadView still drives NetworkService.createSession).
//
// Task 20260914-session-edit-button: also doubles as the edit flow (single
// component, two modes -- per the intake spec's own open question) rather
// than forking a near-duplicate view, since the field set is otherwise
// identical. Passing `existingSession` switches the sheet into edit mode:
// fields are pre-filled from it, a Verses section appears (create mode has
// no verses UI at all, unchanged), and Save drives the caller-supplied
// `onSaveAsync` (real network call + explicit failure surfacing) instead of
// the fire-and-forget `onSave` the create path has always used. The create
// path itself -- onSave, its FSSession field set/order, dismiss-on-tap -- is
// untouched below.
struct SessionCreatorSheet: View {
    let groupId: String
    let existingSession: FSSession?
    let onSave: (FSSession) -> Void
    // Edit-mode save path: a real, throwing, awaitable network call. When
    // present, Save awaits it and only dismisses on success, surfacing a
    // failure via `saveError` instead of the create path's silent
    // fire-and-forget. nil for the create path (unchanged behavior).
    let onSaveAsync: ((FSSession) async throws -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var title:       String
    @State private var startDate:   Date
    @State private var duration:    SessionDuration
    @State private var verses:      [String]
    @State private var verseInput:  String = ""
    @State private var prompts:     [String]
    @State private var promptInput: String = ""
    @State private var recurring:   Bool
    @State private var summarize:   Bool
    @State private var isSaving:    Bool = false
    @State private var saveError:   String?

    private var isEditing: Bool { existingSession != nil }

    init(groupId: String,
         existingSession: FSSession? = nil,
         onSave: @escaping (FSSession) -> Void = { _ in },
         onSaveAsync: ((FSSession) async throws -> Void)? = nil) {
        self.groupId = groupId
        self.existingSession = existingSession
        self.onSave = onSave
        self.onSaveAsync = onSaveAsync

        _title      = State(initialValue: existingSession?.title ?? "")
        _startDate  = State(initialValue: existingSession.flatMap { parseFlexibleISO8601($0.time_start) }
                             ?? Date().addingTimeInterval(3600))
        _duration   = State(initialValue: SessionCreatorSheet.inferredDuration(from: existingSession))
        _verses     = State(initialValue: existingSession?.verses ?? [])
        _prompts    = State(initialValue: existingSession?.prompts ?? [])
        _recurring  = State(initialValue: existingSession?.recurring ?? false)
        _summarize  = State(initialValue: existingSession?.summarize ?? false)
    }

    // `duration` is UI-only (see file header) and FSSession never stores it,
    // so editing has to reconstruct it from the existing time_start/time_end
    // gap, snapping to the nearest of the 4 segmented-control options rather
    // than failing to prefill it at all.
    private static func inferredDuration(from session: FSSession?) -> SessionDuration {
        guard let session,
              let start = parseFlexibleISO8601(session.time_start),
              let end = parseFlexibleISO8601(session.time_end) else {
            return .thirty
        }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        return SessionDuration.allCases.min(by: { abs($0.rawValue - minutes) < abs($1.rawValue - minutes) }) ?? .thirty
    }

    var body: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()

            VStack(spacing: 0) {
                dragHandle
                sheetHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        sessionTitleSection
                        startTimeSection
                        durationSection
                        // Verses editing only exists in edit mode -- the
                        // create path has never had a verses UI (session.verses
                        // is always created empty) and this doesn't add one
                        // there, per the intake spec's "don't alter create
                        // behavior" scope.
                        if isEditing {
                            versesSection
                        }
                        discussionPromptsSection
                        sessionOptionsSection
                    }
                    .padding(.top, 4)
                    .padding(.bottom, Theme.spacingLG)
                }
            }
            .padding(.horizontal, Theme.spacingLG)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(Theme.radiusXXL)
        .preferredColorScheme(.dark)
        .alert("Couldn't Save Changes", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Header

    private var dragHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.2))
            .frame(width: 36, height: 5)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .accessibilityHidden(true)
    }

    private var sheetHeader: some View {
        HStack {
            RoundIconButton(systemIcon: "xmark", diameter: 36) { dismiss() }
                .accessibilityLabel("Cancel")

            Spacer()

            // isEditing branches to a distinct title rather than reusing
            // "Schedule" for an edit -- the literal `Text("Schedule")` below
            // stays reachable (and is still what renders) for the create
            // path, unchanged.
            if isEditing {
                Text("Edit Session")
                    .font(.inter(Theme.fontDisplayMD, weight: .bold))
                    .foregroundColor(Theme.parchment)
            } else {
                Text("Schedule")
                    .font(.inter(Theme.fontDisplayMD, weight: .bold))
                    .foregroundColor(Theme.parchment)
            }

            Spacer()

            // Small circular CTA (mirrors the composer's send-button
            // treatment) rather than plain RoundIconButton styling, so this
            // sheet's primary action keeps its solid-gold weight after
            // losing its "Schedule" pill label.
            Button(action: scheduleSession) {
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Theme.ink)
                    .frame(width: 36, height: 36)
                    .background(Theme.goldGradient)
                    .clipShape(Circle())
                    .topEdgeHighlight(Circle())
            }
            .buttonStyle(.plain)
            .disabled(title.isEmpty)
            .opacity(title.isEmpty ? 0.4 : 1)
            .accessibilityLabel("Schedule session")
        }
        .padding(.bottom, 22)
    }

    // MARK: - Sections

    private var sessionTitleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Session Title")
            TextField("", text: $title, prompt: Text("Evening Study").foregroundColor(Theme.textSecondary))
                .font(.inter(Theme.fontBody))
                .foregroundColor(Theme.parchment)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.045))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusXL).stroke(Theme.borderGoldDim, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXL))
                .topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusXL))
                .accessibilityLabel("Session title")
        }
    }

    private var startTimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Start Time")
            HStack(spacing: 10) {
                DateTimeTile(systemIcon: "calendar", label: "Session start date",
                             date: $startDate, displayedComponents: .date)
                DateTimeTile(systemIcon: "clock", label: "Session start time",
                             date: $startDate, displayedComponents: .hourAndMinute)
            }
        }
    }

    private var durationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Duration")
            SegmentedDurationControl(selection: $duration)
        }
    }

    // Edit-mode only (see body's `if isEditing` gate above) -- mirrors
    // discussionPromptsSection's own add/remove list pattern exactly so this
    // doesn't invent a second list-editing style in the same sheet.
    private var versesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Verses")

            ForEach(Array(verses.enumerated()), id: \.offset) { i, v in
                HStack {
                    Text(v)
                        .font(.inter(Theme.fontSM))
                        .foregroundColor(Theme.parchment)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: { verses.remove(at: i) }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Theme.textMuted)
                    }
                    .accessibilityLabel("Remove verse: \(v)")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.045))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusXL).stroke(Theme.borderGoldDim, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXL))
                .topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusXL))
            }

            HStack {
                TextField("", text: $verseInput,
                          prompt: Text("Add a verse reference…").foregroundColor(Theme.textSecondary))
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .accessibilityLabel("Verse reference input")

                Button(action: addVerse) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.ink)
                        .frame(width: 32, height: 32)
                        .background(verseInput.isEmpty ? AnyShapeStyle(Theme.gold.opacity(0.35)) : AnyShapeStyle(Theme.goldGradient))
                        .clipShape(Circle())
                }
                .disabled(verseInput.isEmpty)
                .accessibilityLabel("Add verse")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.045))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusXL).stroke(Theme.borderGoldDim, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXL))
            .topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusXL))
        }
    }

    private var discussionPromptsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Discussion Prompts")

            ForEach(Array(prompts.enumerated()), id: \.offset) { i, p in
                HStack {
                    Text(p)
                        .font(.inter(Theme.fontSM))
                        .foregroundColor(Theme.parchment)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: { prompts.remove(at: i) }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Theme.textMuted)
                    }
                    .accessibilityLabel("Remove prompt: \(p)")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.045))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusXL).stroke(Theme.borderGoldDim, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXL))
                .topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusXL))
            }

            HStack {
                TextField("", text: $promptInput,
                          prompt: Text("Add a discussion question…").foregroundColor(Theme.textSecondary))
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .accessibilityLabel("Discussion prompt input")

                Button(action: addPrompt) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.ink)
                        .frame(width: 32, height: 32)
                        .background(promptInput.isEmpty ? AnyShapeStyle(Theme.gold.opacity(0.35)) : AnyShapeStyle(Theme.goldGradient))
                        .clipShape(Circle())
                }
                .disabled(promptInput.isEmpty)
                .accessibilityLabel("Add prompt")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.045))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusXL).stroke(Theme.borderGoldDim, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXL))
            .topEdgeHighlight(RoundedRectangle(cornerRadius: Theme.radiusXL))
        }
    }

    private var sessionOptionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Session Options")
            HStack(spacing: 10) {
                ChipToggle(title: "Repeat weekly", isOn: $recurring)
                ChipToggle(title: "Summarize", isOn: $summarize)
            }
        }
    }

    private func addPrompt() {
        let trimmed = promptInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        prompts.append(trimmed)
        promptInput = ""
    }

    private func addVerse() {
        let trimmed = verseInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        verses.append(trimmed)
        verseInput = ""
    }

    // Button(action: scheduleSession) itself is unchanged (still the header
    // CTA's wiring, create and edit alike -- see
    // ChatScheduleUICleanupIOSRegressionTests' source pin on that literal).
    // What it does now branches on mode:
    //  - create (existingSession == nil, onSaveAsync == nil): exactly the
    //    original behavior below -- build a fresh FSSession, fire-and-forget
    //    onSave, dismiss immediately.
    //  - edit (onSaveAsync != nil): start from the *existing* session so id/
    //    creator_id/group_id/participants survive the round trip (the PUT
    //    body is the full FSSession -- see NetworkService+Messaging.swift's
    //    updateSession), await the real network call, and only dismiss on
    //    success -- a failure populates saveError instead of closing, per
    //    this task's explicit-error-propagation requirement.
    private func scheduleSession() {
        guard !isSaving else { return }   // ignore a double-tap while an edit save is in flight

        let df = ISO8601DateFormatter()
        var session = existingSession ?? FSSession()
        session.title      = title
        session.time_start = df.string(from: startDate)
        // FSSession has no duration field — time_end is derived
        // client-side from the segmented control's selection, matching
        // the prior Picker-based flow's behavior. See
        // SessionDuration.timeEndISOString(from:) for the (now
        // independently unit-tested) formula.
        session.time_end   = duration.timeEndISOString(from: startDate)
        session.verses     = verses
        session.prompts    = prompts
        session.recurring  = recurring
        session.summarize  = summarize
        if !isEditing {
            session.id       = UUID().uuidString
            session.group_id = groupId
        }

        guard let onSaveAsync else {
            onSave(session)
            dismiss()
            return
        }

        isSaving = true
        Task {
            do {
                try await onSaveAsync(session)
                await MainActor.run {
                    isSaving = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = "Couldn't save your changes. Please try again."
                }
            }
        }
    }
}

// ── Transient toast (task 20261001-message-threads) ───────────────────────────

/// One bottom toast: "Copied", an error, or "Message deleted  [Undo]".
struct ChatToast: Identifiable {
    let id = UUID()
    let message: String
    let seconds: Double
    var undoTitle: String? = nil
    var undo: (() -> Void)? = nil
}

private struct ChatToastRow: View {
    let toast: ChatToast
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.spacingSM) {
            Text(toast.message)
                .font(.inter(Theme.fontSM))
                .foregroundColor(Theme.parchment)
                .fixedSize(horizontal: false, vertical: true)
            if let title = toast.undoTitle, let undo = toast.undo {
                Spacer(minLength: 8)
                Button(title) {
                    undo()
                    onDismiss()
                }
                .font(.inter(Theme.fontSM, weight: .semibold))
                .foregroundColor(Theme.gold)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(title)
            }
        }
        .padding(.horizontal, Theme.spacingMD)
        .frame(minHeight: 44)
        .background(.regularMaterial)
        .overlay(Capsule().stroke(Theme.borderGoldDim, lineWidth: 1))
        .clipShape(Capsule())
        .task {
            try? await Task.sleep(nanoseconds: UInt64(toast.seconds * 1_000_000_000))
            onDismiss()
        }
    }
}
