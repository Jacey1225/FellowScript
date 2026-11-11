// SharedObjectViews.swift — task 20261012-share-verses-notes-in-chat.
// Approved design (design-approval.json): verse widget variant C (diagonal
// gold/brown split, grain, black Schibsted SemiBold text), note card in the
// NoteRow look with a "From <name>" / "Shared note" badge, a recipient picker
// reached from "Send in chat", and a read-only note view on tap.
//
// The server builds the stored payload and the old-client fallback text; this
// file only renders `attachment_meta` and sends the small request
// (verse reference / note id).

import SwiftUI
import UIKit

// ── Payload (what the sender picked) ─────────────────────────────────────────

enum SharedPayload: Equatable {
    case verse(book: String, chapter: Int, verse: Int, text: String)
    case note(id: String, title: String, preview: String, timestamp: String, isGroup: Bool, ownerUsername: String)

    var kind: FSAttachmentKind {
        switch self {
        case .verse: return .sharedVerse
        case .note:  return .sharedNote
        }
    }

    /// The request the server expects: it re-validates and rebuilds everything else.
    var outgoingMeta: [String: Any] {
        switch self {
        case .verse(let book, let chapter, let verse, _):
            return ["book": book, "chapter": chapter, "verse": verse]
        case .note(let id, _, _, _, _, _):
            return ["note_id": id]
        }
    }

    /// Local echo for the sender's own bubble (the server never re-delivers it).
    var localMeta: FSAttachmentMeta {
        switch self {
        case .verse(let book, let chapter, let verse, let text):
            var m = FSAttachmentMeta()
            m.book = book; m.chapter = chapter; m.verse = verse; m.verseEnd = verse
            m.reference = "\(book) \(chapter):\(verse)"; m.text = text; m.translation = "WEB"
            return m
        case .note(let id, let title, let preview, let timestamp, let isGroup, let owner):
            var m = FSAttachmentMeta()
            m.noteId = id; m.title = title; m.preview = preview; m.timestamp = timestamp
            m.isGroupNote = isGroup; m.ownerUsername = owner
            return m
        }
    }

    /// Same line the server stores as `text` for old clients.
    var fallbackText: String {
        switch self {
        case .verse(let book, let chapter, let verse, let text):
            return "\u{201C}\(text)\u{201D} \u{2014} \(book) \(chapter):\(verse)"
        case .note(_, let title, _, _, _, _):
            return "Shared a note: \(title.isEmpty ? "Untitled note" : title)"
        }
    }

    static func note(_ n: FSNote, ownerUsername: String) -> SharedPayload {
        .note(id: n.id, title: n.title, preview: n.preview, timestamp: n.timestamp,
              isGroup: !n.group_id.isEmpty, ownerUsername: ownerUsername)
    }
}

struct PendingChatShare: Equatable {
    let contact: FSContact
    let payload: SharedPayload
    /// Set when the share targets a thread of `contact` (a group).
    var thread: FSThreadSummary? = nil
}

struct ChatShareDraft: Identifiable {
    let id = UUID()
    let payload: SharedPayload
}

enum SharedObjectText {
    static func verseAccessibilityLabel(_ m: FSMessage, sender: String) -> String {
        let ref = m.attachmentMeta?.reference ?? "verse"
        return "\(sender): Verse \(ref), \(m.attachmentMeta?.text ?? ""). Double tap to read."
    }
    static func noteAccessibilityLabel(_ m: FSMessage, sender: String) -> String {
        let title = (m.attachmentMeta?.title).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled note"
        return "\(sender): Note \(title), opens read only."
    }
}

// ── Grain ────────────────────────────────────────────────────────────────────

/// One tileable monochrome noise tile, generated once (no asset to bundle).
private enum GrainTile {
    static let image: UIImage = {
        let side: CGFloat = 128
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        var seed: UInt32 = 0x9E3779B9
        func next() -> CGFloat {
            seed = seed &* 1664525 &+ 1013904223
            return CGFloat(seed >> 8) / CGFloat(1 << 24)
        }
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { ctx in
            for y in 0..<Int(side) {
                for x in 0..<Int(side) {
                    let v = next()
                    ctx.cgContext.setFillColor(gray: v > 0.5 ? 1 : 0, alpha: 0.25 + 0.5 * abs(v - 0.5))
                    ctx.cgContext.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }()
}

// ── Verse widget (variant C) ─────────────────────────────────────────────────

struct SharedVerseWidget: View {
    let meta: FSAttachmentMeta
    var onTap: (() -> Void)? = nil

    private static let gradient = LinearGradient(
        stops: [
            .init(color: Color(hex: "#EBB340"), location: 0.00),
            .init(color: Color(hex: "#DFA036"), location: 0.28),
            .init(color: Color(hex: "#BC6A2E"), location: 0.58),
            .init(color: Color(hex: "#A55A28"), location: 1.00),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            Text(meta.reference ?? "")
                .font(Font.schibstedWordmark(12, relativeTo: .caption))
                .textCase(.uppercase)
                .tracking(0.9)
                .foregroundColor(.black.opacity(0.9))
            Text(meta.text ?? "")
                .font(Font.schibstedWordmark(19, relativeTo: .body))
                .tracking(-0.01 * 19)
                .foregroundColor(.black)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("FellowScript")
                Spacer(minLength: 8)
                Text("Tap to read")
            }
            .font(Font.schibstedWordmark(11, relativeTo: .caption2))
            .foregroundColor(.black.opacity(0.88))
        }
        .padding(18)
        .frame(maxWidth: 340, alignment: .leading)
        .background(
            ZStack {
                Self.gradient
                Image(uiImage: GrainTile.image)
                    .resizable(resizingMode: .tile)
                    .opacity(0.5)
                    .blendMode(.overlay)
                    .allowsHitTesting(false)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

        if let onTap {
            Button(action: onTap) { content }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
        } else {
            content
        }
    }
}

// ── Note card (NoteRow look) ─────────────────────────────────────────────────

/// Defense-in-depth: the server strips markup from note previews, but older
/// stored rows, cached messages, or an un-deployed server can still carry rich
/// text HTML. Strips tags (script/style content dropped, block tags become
/// spaces), decodes common entities, and collapses whitespace. Pure string work.
enum SharedNotePreview {
    private static let blockTags: Set<String> = [
        "p", "div", "br", "li", "ul", "ol", "tr", "td", "th", "blockquote", "pre", "hr",
        "h1", "h2", "h3", "h4", "h5", "h6", "section", "article", "table",
    ]

    static func plainText(_ raw: String?) -> String {
        guard let raw = raw, !raw.isEmpty else { return "" }
        guard raw.contains("<") || raw.contains("&") else {
            return collapse(raw)
        }
        var out = ""
        var skipUntil: String? = nil   // closing tag name for script/style
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if c == "<" {
                // A tag starts only before a letter, "/" or "!"; otherwise literal "<".
                let next = raw.index(after: i)
                let startsTag = next < raw.endIndex && (raw[next].isLetter || raw[next] == "/" || raw[next] == "!")
                if startsTag {
                    if let close = raw[next...].firstIndex(of: ">") {
                        var inner = raw[next..<close].lowercased()
                        let isClosing = inner.hasPrefix("/")
                        if isClosing { inner.removeFirst() }
                        let name = String(inner.prefix { $0.isLetter || $0.isNumber })
                        if let want = skipUntil {
                            if isClosing && name == want { skipUntil = nil }
                        } else if !isClosing && (name == "script" || name == "style") && !inner.hasSuffix("/") {
                            skipUntil = name
                        } else if blockTags.contains(name) {
                            out.append(" ")
                        }
                        i = raw.index(after: close)
                        continue
                    } else {
                        // Unclosed tag: drop the remainder rather than leak markup.
                        break
                    }
                }
            }
            if skipUntil == nil { out.append(c) }
            i = raw.index(after: i)
        }
        return collapse(decodeEntities(out))
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0 == "\u{00A0}" }).joined(separator: " ")
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
    ]

    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let body = String(s[s.index(after: i)..<semi])
                var rep: String? = named[body.lowercased()]
                if rep == nil, body.hasPrefix("#") {
                    let num = body.dropFirst()
                    let code: UInt32? = (num.hasPrefix("x") || num.hasPrefix("X"))
                        ? UInt32(num.dropFirst(), radix: 16) : UInt32(num)
                    if let code = code, let sc = Unicode.Scalar(code) { rep = String(Character(sc)) }
                }
                if let rep = rep {
                    out.append(rep)
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}

struct SharedNoteCard: View {
    let meta: FSAttachmentMeta
    var unavailable = false
    var loading = false

    private var dateText: String {
        var n = FSNote(); n.timestamp = meta.timestamp ?? ""
        return n.formattedTimestamp
    }

    private var badgeText: String {
        guard meta.isGroupNote == true else { return "Shared note" }
        let who = meta.ownerUsername ?? ""
        return who.isEmpty ? "Group" : "From \(who) \u{00B7} Group"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(unavailable ? "Note unavailable" : ((meta.title ?? "").isEmpty ? "Untitled" : meta.title ?? ""))
                    .font(.system(size: 16.5, weight: .heavy))
                    .foregroundColor(Theme.parchment)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if loading { ProgressView().tint(Theme.gold).scaleEffect(0.8) }
            }
            if unavailable {
                Text("This note is no longer shared.")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.parchment.opacity(0.62))
            } else {
                Text(SharedNotePreview.plainText(meta.preview).isEmpty ? "No content" : SharedNotePreview.plainText(meta.preview))
                    .font(.system(size: 13))
                    .foregroundColor(Theme.parchment.opacity(0.62))
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(dateText)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    if meta.isGroupNote != true {
                        Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                    }
                    Text(badgeText).font(.system(size: 11, weight: .bold)).lineLimit(1)
                }
                .foregroundColor(Theme.goldLight)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.gold.opacity(0.14))
                .overlay(Capsule().stroke(Theme.gold.opacity(0.32), lineWidth: 1))
                .clipShape(Capsule())
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .glassCard(cornerRadius: 20)
        .opacity(unavailable ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unavailable ? "Note unavailable" : "Note \((meta.title ?? "").isEmpty ? "Untitled" : meta.title ?? ""), opens read only")
        .accessibilityAddTraits(.isButton)
    }
}

// ── In-chat dispatcher ───────────────────────────────────────────────────────

/// Renders a `shared_verse` / `shared_note` message and handles its tap.
struct SharedObjectContentView: View {
    let message: FSMessage
    @EnvironmentObject private var appState: AppState

    @State private var openedNote: OpenedSharedNote? = nil
    @State private var isOpening = false
    @State private var unavailable = false
    @State private var showUnavailableAlert = false

    var body: some View {
        let meta = message.attachmentMeta ?? FSAttachmentMeta()
        Group {
            switch message.attachmentKindEnum {
            case .sharedVerse:
                SharedVerseWidget(meta: meta, onTap: { openVerse(meta) })
            case .sharedNote:
                Button(action: openNote) {
                    SharedNoteCard(meta: meta, unavailable: unavailable, loading: isOpening)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .disabled(isOpening)
            default:
                EmptyView()
            }
        }
        .sheet(item: $openedNote) { opened in
            NoteDetailView(
                note: opened.note,
                userId: appState.currentUser?.user_id ?? "",
                username: appState.currentUser?.username ?? "",
                service: appState.service,
                readOnly: true,
                sharedBanner: opened.banner
            ) { _ in nil }
        }
        .alert("Note unavailable", isPresented: $showUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This note is no longer shared.")
        }
    }

    private func openVerse(_ meta: FSAttachmentMeta) {
        guard let book = meta.book, let ch = meta.chapter, let v = meta.verse else { return }
        appState.pendingBibleNav = BibleNavTarget(book: book, chapter: ch, verse: v)
    }

    private func openNote() {
        guard !isOpening, let uid = appState.currentUser?.user_id,
              let svc = appState.service as? SharedObjectsService else { return }
        isOpening = true
        let sender = message.mine ? "you" : (message.sender.isEmpty ? "a friend" : message.sender)
        let mid = message.id
        Task {
            defer { isOpening = false }
            do {
                let shared = try await svc.fetchSharedNote(userId: uid, messageId: mid)
                unavailable = false
                openedNote = OpenedSharedNote(
                    note: shared.note,
                    banner: "Shared by \(sender) in this chat. You can view but not edit.")
            } catch {
                unavailable = true
                showUnavailableAlert = true
            }
        }
    }
}

private struct OpenedSharedNote: Identifiable {
    let id = UUID()
    let note: FSNote
    let banner: String
}

// ── "Send in chat" recipient picker ──────────────────────────────────────────

extension View {
    /// Presents the recipient picker for `item` (a verse or note to send).
    func chatShareSheet(item: Binding<ChatShareDraft?>) -> some View {
        sheet(item: item) { draft in
            ShareToChatSheet(draft: draft)
                .presentationDetents([.large])
        }
    }
}

struct ShareToChatSheet: View {
    let draft: ChatShareDraft
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var friends: [FSContact] = []
    @State private var groups:  [FSContact] = []
    @State private var loaded = false
    @State private var failed = false
    private var threadsPickable: Bool {
        appState.capabilities.isEnabled("threads") && appState.capabilities.sharedObjectsEnabled
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingMD) {
                    HStack {
                        Text("Send in chat")
                            .font(.system(size: Theme.fontDisplayMD, weight: .heavy))
                            .foregroundColor(Theme.parchment)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("Cancel") { dismiss() }
                            .font(.system(size: Theme.fontSM, weight: .semibold))
                            .foregroundColor(Theme.gold)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    preview
                    if !loaded {
                        HStack { Spacer(); ProgressView().tint(Theme.gold); Spacer() }.padding(.top, 24)
                    } else if failed {
                        Text("Couldn't load your chats. Try again in a moment.")
                            .font(.system(size: Theme.fontSM)).foregroundColor(Theme.textSecondary)
                    } else if friends.isEmpty && groups.isEmpty {
                        Text("No chats yet")
                            .font(.system(size: Theme.fontSM)).foregroundColor(Theme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.top, 24)
                    } else {
                        section("Friends", friends)
                        section("Groups", groups)
                    }
                }
                .padding(Theme.spacingMD)
            }
        }
        .warmBloomBackground()
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    @ViewBuilder private var preview: some View {
        switch draft.payload {
        case .verse: SharedVerseWidget(meta: draft.payload.localMeta)
        case .note:  SharedNoteCard(meta: draft.payload.localMeta)
        }
    }

    @ViewBuilder private func section(_ title: String, _ contacts: [FSContact]) -> some View {
        if !contacts.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold)).tracking(1.0)
                .foregroundColor(Theme.textMuted)
                .padding(.top, Theme.spacingSM)
            ForEach(contacts) { c in
                Button { send(to: c) } label: {
                    HStack(spacing: 12) {
                        AvatarView(initial: String(c.name.prefix(1)).uppercased(), photoURL: c.photoUrl,
                                   diameter: 36, fillColor: Theme.gold.opacity(0.14), textColor: Theme.goldLight)
                        Text(c.name).font(.system(size: Theme.fontBody, weight: .semibold))
                            .foregroundColor(Theme.parchment).lineLimit(1)
                        Spacer()
                        Image(systemName: "paperplane").foregroundColor(Theme.gold)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(minHeight: 52)
                    .glassCard(cornerRadius: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send to \(c.name)")
                if c.type == .group, threadsPickable {
                    ShareGroupThreadsRows(group: c, service: appState.service,
                                          userId: appState.currentUser?.user_id ?? "") { send(to: c, thread: $0) }
                }
            }
        }
    }

    private func load() async {
        guard let uid = appState.currentUser?.user_id else { loaded = true; failed = true; return }
        do {
            let (contacts, _) = try await appState.service.fetchContacts(userId: uid)
            friends = contacts.filter { $0.type == .friend }.sorted { $0.lastMessageAt > $1.lastMessageAt }
            groups  = contacts.filter { $0.type == .group  }.sorted { $0.lastMessageAt > $1.lastMessageAt }
        } catch {
            failed = true
        }
        loaded = true
    }

    /// Hands the share to the target chat (it sends over the one chat socket once
    /// loaded) and opens that chat on the Chat tab.
    private func send(to contact: FSContact, thread: FSThreadSummary? = nil) {
        appState.pendingChatShare = PendingChatShare(contact: contact, payload: draft.payload, thread: thread)
        appState.pendingChatContact = contact
        dismiss()
    }
}
