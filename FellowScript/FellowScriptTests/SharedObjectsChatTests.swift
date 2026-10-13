// SharedObjectsChatTests.swift -- testing gate (iOS half), task
// 20261012-share-verses-notes-in-chat, step 7.
//
// Covers: wire decode of shared_verse / shared_note attachment_meta (and old
// payloads unaffected), FSAttachmentKind, the capability flag failing closed,
// SharedPayload (request carries only reference/note_id, local echo, fallback
// text), accessibility labels, the real NetworkService.fetchSharedNote against a
// stubbed URL protocol (200 happy path, uniform "unavailable" on every failure),
// NoteDetailView read-only edit gating, and the ChatThreadViewModel send frame
// (recorded off a real local websocket) including retry-as-share and ack cleanup.
// Plain XCTest; no UI hosting.

import XCTest
import Network
@testable import FellowScript

// MARK: - Wire decode and model

final class SharedObjectsModelTests: XCTestCase {

    private func raw(_ json: String) throws -> RawMsg {
        try JSONDecoder().decode(RawMsg.self, from: Data(json.utf8))
    }

    func test_verseMessage_decodesStructuredMeta() throws {
        let json = #"""
        {"id":"m1","text":"“In the beginning” — Genesis 1:1","from_user":"ann","timestamp":"2026-10-12T10:00:00Z","mine":false,
         "attachment_kind":"shared_verse",
         "attachment_meta":{"book":"Genesis","chapter":1,"verse":1,"verse_end":1,"reference":"Genesis 1:1","text":"In the beginning","translation":"WEB"}}
        """#
        let msg = NetworkService.pagedMessage(try raw(json))
        XCTAssertEqual(msg.attachmentKindEnum, .sharedVerse)
        XCTAssertEqual(msg.attachmentKindEnum?.isShared, true)
        XCTAssertEqual(msg.attachmentMeta?.book, "Genesis")
        XCTAssertEqual(msg.attachmentMeta?.chapter, 1)
        XCTAssertEqual(msg.attachmentMeta?.verse, 1)
        XCTAssertEqual(msg.attachmentMeta?.verseEnd, 1)
        XCTAssertEqual(msg.attachmentMeta?.reference, "Genesis 1:1")
        XCTAssertEqual(msg.attachmentMeta?.text, "In the beginning")
        XCTAssertEqual(msg.attachmentMeta?.translation, "WEB")
    }

    func test_noteMessage_decodesStructuredMeta() throws {
        let json = #"""
        {"id":"m2","text":"Shared a note: Psalm study","from_user":"ann","timestamp":"2026-10-12T10:00:00Z","mine":false,
         "attachment_kind":"shared_note",
         "attachment_meta":{"note_id":"n1","title":"Psalm study","preview":"Notes on 23","timestamp":"2026-10-11T09:00:00Z",
                            "is_group_note":true,"owner_username":"ann","owner_id":"u1"}}
        """#
        let msg = NetworkService.pagedMessage(try raw(json))
        XCTAssertEqual(msg.attachmentKindEnum, .sharedNote)
        let m = msg.attachmentMeta
        XCTAssertEqual(m?.noteId, "n1")
        XCTAssertEqual(m?.title, "Psalm study")
        XCTAssertEqual(m?.preview, "Notes on 23")
        XCTAssertEqual(m?.isGroupNote, true)
        XCTAssertEqual(m?.ownerUsername, "ann")
        XCTAssertEqual(m?.ownerId, "u1")
    }

    func test_existingAttachmentKinds_stillDecode_andAreNotShared() throws {
        let json = #"{"id":"m3","text":"","from_user":"bob","timestamp":"t","mine":false,"attachment_kind":"image","attachment_meta":{"width":10,"height":20}}"#
        let msg = NetworkService.pagedMessage(try raw(json))
        XCTAssertEqual(msg.attachmentKindEnum, .image)
        XCTAssertEqual(msg.attachmentKindEnum?.isShared, false)
        XCTAssertEqual(msg.attachmentMeta?.width, 10)
        XCTAssertNil(msg.attachmentMeta?.book)
        XCTAssertNil(msg.attachmentMeta?.noteId)
        for k in [FSAttachmentKind.image, .video, .file, .gif] { XCTAssertFalse(k.isShared) }
        XCTAssertTrue(FSAttachmentKind.sharedVerse.isShared)
        XCTAssertTrue(FSAttachmentKind.sharedNote.isShared)
    }

    func test_kindRawValues_matchServer() {
        XCTAssertEqual(FSAttachmentKind.sharedVerse.rawValue, "shared_verse")
        XCTAssertEqual(FSAttachmentKind.sharedNote.rawValue, "shared_note")
        XCTAssertNil(FSAttachmentKind(rawValue: "shared_other"))
    }

    func test_meta_roundTripsThroughCodable() throws {
        var m = FSAttachmentMeta()
        m.noteId = "n"; m.isGroupNote = true; m.verseEnd = 3; m.ownerUsername = "o"
        let back = try JSONDecoder().decode(FSAttachmentMeta.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
        // Wire key names, not Swift property names.
        let enc = String(data: try JSONEncoder().encode(m), encoding: .utf8) ?? ""
        XCTAssertTrue(enc.contains("note_id")); XCTAssertTrue(enc.contains("is_group_note"))
        XCTAssertTrue(enc.contains("verse_end")); XCTAssertTrue(enc.contains("owner_username"))
    }

    func test_replyPreviewText_namesSharedKinds() {
        func m(_ k: String) -> FSMessage { FSMessage(id: "1", text: " ", mine: false, sender: "x", timestamp: "t", attachmentKind: k) }
        XCTAssertEqual(m("shared_verse").replyPreviewText, "Verse")
        XCTAssertEqual(m("shared_note").replyPreviewText, "Note")
    }

    func test_capability_failsClosed() throws {
        let on = #"{"features":{"chat_shared_objects":true},"terms_current":true}"#
        XCTAssertTrue(try JSONDecoder().decode(FSCapabilities.self, from: Data(on.utf8)).sharedObjectsEnabled)
        let off = #"{"features":{"chat_shared_objects":false},"terms_current":true}"#
        XCTAssertFalse(try JSONDecoder().decode(FSCapabilities.self, from: Data(off.utf8)).sharedObjectsEnabled)
        let missing = #"{"features":{},"terms_current":true}"#
        XCTAssertFalse(try JSONDecoder().decode(FSCapabilities.self, from: Data(missing.utf8)).sharedObjectsEnabled)
        XCTAssertFalse(FSCapabilities.allOff.sharedObjectsEnabled)
    }
}

// MARK: - SharedPayload

final class SharedPayloadTests: XCTestCase {

    private let verse = SharedPayload.verse(book: "John", chapter: 3, verse: 16, text: "For God so loved the world")

    func test_verse_outgoingMetaCarriesOnlyReference() {
        let meta = verse.outgoingMeta
        XCTAssertEqual(Set(meta.keys), ["book", "chapter", "verse"])
        XCTAssertEqual(meta["book"] as? String, "John")
        XCTAssertEqual(meta["chapter"] as? Int, 3)
        XCTAssertEqual(meta["verse"] as? Int, 16)
        XCTAssertNil(meta["text"], "verse text is rebuilt server-side, never sent")
    }

    func test_note_outgoingMetaCarriesOnlyNoteId() {
        let p = SharedPayload.note(id: "n1", title: "Secret title", preview: "Secret preview",
                                   timestamp: "t", isGroup: true, ownerUsername: "ann")
        XCTAssertEqual(Set(p.outgoingMeta.keys), ["note_id"])
        XCTAssertEqual(p.outgoingMeta["note_id"] as? String, "n1")
    }

    func test_kinds() {
        XCTAssertEqual(verse.kind, .sharedVerse)
        XCTAssertEqual(SharedPayload.note(id: "n", title: "", preview: "", timestamp: "", isGroup: false, ownerUsername: "").kind, .sharedNote)
    }

    func test_verse_localMeta_echo() {
        let m = verse.localMeta
        XCTAssertEqual(m.reference, "John 3:16")
        XCTAssertEqual(m.text, "For God so loved the world")
        XCTAssertEqual(m.book, "John"); XCTAssertEqual(m.chapter, 3); XCTAssertEqual(m.verse, 16)
        XCTAssertEqual(m.translation, "WEB")
    }

    func test_note_localMeta_echo() {
        let p = SharedPayload.note(id: "n1", title: "T", preview: "P", timestamp: "2026-10-11T09:00:00Z", isGroup: true, ownerUsername: "ann")
        let m = p.localMeta
        XCTAssertEqual(m.noteId, "n1"); XCTAssertEqual(m.title, "T"); XCTAssertEqual(m.preview, "P")
        XCTAssertEqual(m.isGroupNote, true); XCTAssertEqual(m.ownerUsername, "ann")
    }

    func test_fallbackText() {
        XCTAssertEqual(verse.fallbackText, "\u{201C}For God so loved the world\u{201D} \u{2014} John 3:16")
        XCTAssertEqual(SharedPayload.note(id: "n", title: "Study", preview: "", timestamp: "", isGroup: false, ownerUsername: "").fallbackText,
                       "Shared a note: Study")
        XCTAssertEqual(SharedPayload.note(id: "n", title: "", preview: "", timestamp: "", isGroup: false, ownerUsername: "").fallbackText,
                       "Shared a note: Untitled note")
    }

    func test_noteFactory_groupFlagFromGroupId() {
        var personal = FSNote(); personal.id = "p"; personal.title = "A"
        var group = FSNote(); group.id = "g"; group.group_id = "grp"
        guard case .note(let pid, _, _, _, let pg, let po) = SharedPayload.note(personal, ownerUsername: "me"),
              case .note(let gid, _, _, _, let gg, _) = SharedPayload.note(group, ownerUsername: "me") else { return XCTFail() }
        XCTAssertEqual(pid, "p"); XCTAssertFalse(pg); XCTAssertEqual(po, "me")
        XCTAssertEqual(gid, "g"); XCTAssertTrue(gg)
    }

    func test_accessibilityLabels() {
        var meta = FSAttachmentMeta(); meta.reference = "John 3:16"; meta.text = "For God so loved"
        let vm = FSMessage(id: "1", text: "", mine: false, sender: "ann", timestamp: "t", attachmentKind: "shared_verse", attachmentMeta: meta)
        XCTAssertEqual(SharedObjectText.verseAccessibilityLabel(vm, sender: "ann"), "ann: Verse John 3:16, For God so loved. Double tap to read.")
        var nm = FSAttachmentMeta(); nm.title = "Study"
        let nmsg = FSMessage(id: "2", text: "", mine: false, sender: "ann", timestamp: "t", attachmentKind: "shared_note", attachmentMeta: nm)
        XCTAssertEqual(SharedObjectText.noteAccessibilityLabel(nmsg, sender: "ann"), "ann: Note Study, opens read only.")
        let untitled = FSMessage(id: "3", text: "", mine: false, sender: "ann", timestamp: "t", attachmentKind: "shared_note", attachmentMeta: FSAttachmentMeta())
        XCTAssertEqual(SharedObjectText.noteAccessibilityLabel(untitled, sender: "ann"), "ann: Note Untitled note, opens read only.")
    }
}

// MARK: - Fetch (real NetworkService, stubbed transport)

final class SharedNoteFetchTests: XCTestCase {

    override class func setUp() { super.setUp(); URLProtocol.registerClass(PagingStubURLProtocol.self) }
    override class func tearDown() { URLProtocol.unregisterClass(PagingStubURLProtocol.self); super.tearDown() }
    override func setUp() { PagingStubURLProtocol.reset() }
    /// Decode failures fire an async client-error report; let it land on this class's stub
    /// before the stub is unregistered so it cannot leak into a later test class's request log.
    override func tearDown() async throws { try? await Task.sleep(nanoseconds: 600_000_000) }

    private let svc = NetworkService.shared
    private let path = "/api/shared-objects/u1/note/m1"

    private let okBody = #"{"note_id":"n1","title":"Study","text":"<p>Body</p>","public":false,"group_id":"grp-1","timestamp":"2026-10-11T09:00:00Z","verses":[],"read_only":true,"shared_by":"ann","replies":[]}"#

    func test_success_decodesNote_readOnly_andStripsGroupId() async throws {
        PagingStubURLProtocol.routes[path] = (200, okBody)
        let r = try await svc.fetchSharedNote(userId: "u1", messageId: "m1")
        XCTAssertEqual(r.note.id, "n1")
        XCTAssertEqual(r.note.title, "Study")
        XCTAssertEqual(r.note.group_id, "", "no group id: no replies or group-edit rules in the read-only view")
        XCTAssertEqual(r.sharedBy, "ann")
        XCTAssertTrue(PagingStubURLProtocol.urls.last?.hasSuffix(path) == true)
    }

    func test_404_isUnavailable() async {
        PagingStubURLProtocol.routes[path] = (404, #"{"detail":"not_found"}"#)
        do { _ = try await svc.fetchSharedNote(userId: "u1", messageId: "m1"); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? FSSharedObjectError, .unavailable) }
    }

    func test_serverError_isUnavailable() async {
        PagingStubURLProtocol.routes[path] = (500, "{}")
        do { _ = try await svc.fetchSharedNote(userId: "u1", messageId: "m1"); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? FSSharedObjectError, .unavailable) }
    }

    func test_200WithoutReadOnlyFlag_isRejected() async {
        PagingStubURLProtocol.routes[path] = (200, #"{"note_id":"n1","title":"x","text":"y","read_only":false}"#)
        do { _ = try await svc.fetchSharedNote(userId: "u1", messageId: "m1"); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? FSSharedObjectError, .unavailable) }
    }

    func test_200WithoutNoteId_orGarbage_isRejected() async {
        PagingStubURLProtocol.routes[path] = (200, #"{"title":"x","text":"y","read_only":true}"#)
        do { _ = try await svc.fetchSharedNote(userId: "u1", messageId: "m1"); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? FSSharedObjectError, .unavailable) }
        PagingStubURLProtocol.routes[path] = (200, "not json")
        do { _ = try await svc.fetchSharedNote(userId: "u1", messageId: "m1"); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? FSSharedObjectError, .unavailable) }
    }

    func test_emptySharedBy_isNil() async throws {
        PagingStubURLProtocol.routes[path] = (200, #"{"note_id":"n1","title":"x","text":"y","read_only":true,"shared_by":""}"#)
        let r = try await svc.fetchSharedNote(userId: "u1", messageId: "m1")
        XCTAssertNil(r.sharedBy)
    }

    func test_mockService_neverFabricatesAShare() async {
        do { _ = try await MockDataService.shared.fetchSharedNote(userId: "u", messageId: "m"); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? FSSharedObjectError, .unavailable) }
    }
}

// MARK: - NoteDetailView read-only gating

final class SharedNoteReadOnlyTests: XCTestCase {

    private func note(group: String = "", isPublic: Bool = false, owner: String = "") -> FSNote {
        var n = FSNote(); n.id = "n"; n.title = "T"; n.group_id = group; n.public = isPublic; n.username = owner
        return n
    }

    func test_readOnly_neverCanEdit_evenForPersonalOrPublicOrOwnNote() {
        XCTAssertFalse(NoteDetailView(note: note(), readOnly: true) { _ in nil }.canEdit)
        XCTAssertFalse(NoteDetailView(note: note(group: "g", isPublic: true), readOnly: true) { _ in nil }.canEdit)
        XCTAssertFalse(NoteDetailView(note: note(group: "g", owner: "me"), username: "me", readOnly: true) { _ in nil }.canEdit)
    }

    func test_default_isStillEditable_exceptingExistingRules() {
        XCTAssertTrue(NoteDetailView(note: note()) { _ in nil }.canEdit)
        XCTAssertTrue(NoteDetailView(note: note(group: "g", isPublic: true)) { _ in nil }.canEdit)
        XCTAssertTrue(NoteDetailView(note: note(group: "g", owner: "me"), username: "me") { _ in nil }.canEdit)
        XCTAssertFalse(NoteDetailView(note: note(group: "g", owner: "ann"), username: "me") { _ in nil }.canEdit)
    }
}

// MARK: - View model send frame (recorded off a real local websocket)

final class RecordingWSServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "shared-objects-test.server")
    private let lock = NSLock()
    private var ready = false
    private var conns: [NWConnection] = []
    private var frames: [[String: Any]] = []

    init() throws {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params)
        listener.stateUpdateHandler = { [weak self] s in
            if case .ready = s { self?.lock.lock(); self?.ready = true; self?.lock.unlock() }
        }
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.stateUpdateHandler = { [weak self] s in
                if case .ready = s, let self { self.lock.lock(); self.conns.append(c); self.lock.unlock() }
            }
            c.start(queue: self.queue)
            self.read(c)
        }
    }
    private func read(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self, err == nil else { return }
            if let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                self.lock.lock(); self.frames.append(obj); self.lock.unlock()
            }
            self.read(c)
        }
    }
    func start() async throws -> UInt16 {
        listener.start(queue: queue)
        for _ in 0..<100 {
            lock.lock(); let r = ready; lock.unlock()
            if r, let p = listener.port, p.rawValue != 0 { return p.rawValue }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "RecordingWSServer", code: 1)
    }
    func stop() { listener.cancel() }
    func waitForConnection() async throws {
        let end = Date().addingTimeInterval(8)
        while Date() < end {
            lock.lock(); let has = !conns.isEmpty; lock.unlock()
            if has { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "RecordingWSServer", code: 2)
    }
    func sendFrame(_ json: [String: Any]) throws {
        lock.lock(); let c = conns.last; lock.unlock()
        guard let c else { throw NSError(domain: "RecordingWSServer", code: 3) }
        let data = try JSONSerialization.data(withJSONObject: json)
        let md = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "t", metadata: [md])
        c.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }
    var received: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return frames }
}

@MainActor
final class SharedObjectsSendTests: XCTestCase {

    override func setUp() { ReactionSeam.reset(); ThreadsSeam.reset() }

    private let friend = FSContact(id: "friend-1", name: "Ann", type: .friend)
    private let verse = SharedPayload.verse(book: "John", chapter: 3, verse: 16, text: "For God so loved the world")
    private let note = SharedPayload.note(id: "n1", title: "Study", preview: "Body", timestamp: "2026-10-11T09:00:00Z", isGroup: false, ownerUsername: "me")

    private func eventually(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return }; try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTFail("timed out waiting: \(what)")
    }

    private func withServer(_ body: (RecordingWSServer, ChatThreadViewModel, String) async throws -> Void) async throws {
        let server = try RecordingWSServer()
        let port = try await server.start()
        defer { server.stop() }
        let s = ThrowingTestDataService()
        s.wsBaseOverride = "ws://127.0.0.1:\(port)"
        s.historyResult = .paged(FSMessagePage(messages: [], hasMore: false, cursor: nil))
        let user = "ws-\(UUID().uuidString)"
        let vm = ChatThreadViewModel()
        await vm.load(service: s, contact: friend, userId: user,
                      capabilities: FSCapabilities(features: ["chat_pagination": true, "chat_pagination_dm": true], exploreLink: nil, termsCurrent: true))
        try await server.waitForConnection()
        try await body(server, vm, user)
        vm.disconnect()
    }

    func test_verseSend_frameCarriesKindAndReferenceOnly_andEchoesLocally() async throws {
        try await withServer { server, vm, user in
            vm.sendMessage(text: self.verse.fallbackText, attachment: nil, contact: self.friend, userId: user, shared: self.verse)
            await self.eventually("frame") { !server.received.isEmpty }
            let f = server.received.last!
            XCTAssertEqual(f["attachment_kind"] as? String, "shared_verse")
            let meta = f["attachment_meta"] as? [String: Any]
            XCTAssertEqual(Set((meta ?? [:]).keys), ["book", "chapter", "verse"])
            XCTAssertNil(f["attachment_key"], "shares have no uploaded object")
            let local = vm.messages.last
            XCTAssertEqual(local?.attachmentKindEnum, .sharedVerse)
            XCTAssertEqual(local?.attachmentMeta?.reference, "John 3:16")
            XCTAssertTrue(local?.mine == true)
        }
    }

    func test_noteSend_frameCarriesOnlyNoteId_noTitleOrPreview() async throws {
        try await withServer { server, vm, user in
            vm.sendMessage(text: self.note.fallbackText, attachment: nil, contact: self.friend, userId: user, shared: self.note)
            await self.eventually("frame") { !server.received.isEmpty }
            let f = server.received.last!
            XCTAssertEqual(f["attachment_kind"] as? String, "shared_note")
            let meta = f["attachment_meta"] as? [String: Any]
            XCTAssertEqual(meta?["note_id"] as? String, "n1")
            XCTAssertEqual(Set((meta ?? [:]).keys), ["note_id"])
            XCTAssertEqual(vm.messages.last?.attachmentMeta?.noteId, "n1")
        }
    }

    func test_plainSend_hasNoAttachmentFields() async throws {
        try await withServer { server, vm, user in
            vm.sendMessage(text: "hello", attachment: nil, contact: self.friend, userId: user)
            await self.eventually("frame") { !server.received.isEmpty }
            let f = server.received.last!
            XCTAssertNil(f["attachment_kind"]); XCTAssertNil(f["attachment_meta"])
            XCTAssertNil(vm.messages.last?.attachmentKind)
        }
    }

    func test_failedShare_retriesAsShare_notPlainText() async throws {
        try await withServer { server, vm, user in
            vm.sendMessage(text: self.verse.fallbackText, attachment: nil, contact: self.friend, userId: user, shared: self.verse)
            guard let local = vm.messages.last else { return XCTFail("no bubble") }
            await self.eventually("first frame") { server.received.count == 1 }
            try server.sendFrame(["type": "error", "reason": "rate_limited"])
            await self.eventually("failed") { vm.failedMessageIds.contains(local.id) }
            vm.retryFailedMessage(local.id, contact: self.friend, userId: user)
            await self.eventually("retry frame") { server.received.count == 2 }
            let f = server.received.last!
            XCTAssertEqual(f["attachment_kind"] as? String, "shared_verse")
            XCTAssertEqual((f["attachment_meta"] as? [String: Any])?["book"] as? String, "John")
            XCTAssertFalse(vm.messages.contains { $0.id == local.id }, "old failed bubble replaced")
        }
    }

    func test_ack_keepsSharedKindOnBubble() async throws {
        try await withServer { server, vm, user in
            vm.sendMessage(text: self.note.fallbackText, attachment: nil, contact: self.friend, userId: user, shared: self.note)
            guard let local = vm.messages.last else { return XCTFail("no bubble") }
            try server.sendFrame(["type": "ack", "client_ref": local.id, "id": "srv-1", "timestamp": "2026-10-12T10:02:00Z"])
            await self.eventually("ack") { vm.messages.contains { $0.id == "srv-1" } }
            XCTAssertEqual(vm.messages.first { $0.id == "srv-1" }?.attachmentKindEnum, .sharedNote)
        }
    }

    func test_inboundLiveFrame_rendersSharedKind() async throws {
        try await withServer { server, vm, _ in
            try server.sendFrame(["id": "m9", "text": "Shared a note: Study", "from_user": "friend-1", "timestamp": "2026-10-12T10:03:00Z",
                                  "attachment_kind": "shared_note",
                                  "attachment_meta": ["note_id": "n1", "title": "Study", "preview": "Body", "is_group_note": false]])
            await self.eventually("frame") { vm.messages.contains { $0.id == "m9" } }
            let m = vm.messages.first { $0.id == "m9" }
            XCTAssertEqual(m?.attachmentKindEnum, .sharedNote)
            XCTAssertEqual(m?.attachmentMeta?.title, "Study")
        }
    }
}


// MARK: - Note preview HTML stripping (task 20261013-shared-note-preview-html-leak)

final class SharedNotePreviewTests: XCTestCase {
    func test_stripsBoldTagFromScreenshotCase() {
        XCTAssertEqual(SharedNotePreview.plainText("<b>Matthew 28:19 \u{2014} Go and make disciples...</b>"),
                       "Matthew 28:19 \u{2014} Go and make disciples...")
    }
    func test_blockTagsBecomeSpacesAndEntitiesDecode() {
        XCTAssertEqual(SharedNotePreview.plainText("<p>a &amp; b</p><p>it&#39;s&nbsp;ok</p>line<br>two"),
                       "a & b it's ok line two")
    }
    func test_scriptAndStyleContentDropped() {
        XCTAssertEqual(SharedNotePreview.plainText("hi<script>alert(1)</script><style>p{}</style>there"), "hithere")
    }
    func test_imgOnerrorAndUnclosedTagsInert() {
        XCTAssertEqual(SharedNotePreview.plainText("x<img src=x onerror=alert(1)>y"), "xy")
        XCTAssertEqual(SharedNotePreview.plainText("safe <b onclick=\"x"), "safe")
    }
    func test_plainTextAndLiteralLessThanPreserved() {
        XCTAssertEqual(SharedNotePreview.plainText("1 < 2 and  3"), "1 < 2 and 3")
        XCTAssertEqual(SharedNotePreview.plainText(nil), "")
        XCTAssertEqual(SharedNotePreview.plainText("<p></p>"), "")
    }
}
