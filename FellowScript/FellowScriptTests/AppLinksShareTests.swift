// AppLinksShareTests.swift — task 20261011-ios-share-notes-highlights, step 8.
// Pure tests: AppLink parser round trips (u / v / g, plus the existing /join
// invite kind staying separate), hostile URL rejection, verse bounds, share
// payload builders (note / verse / announcement exclusions), the creator-name
// fallback, unpublished-group hiding, and AppState routing (deferred until auth,
// confirm only, never sent). No network, no simulator features.

import XCTest
@testable import FellowScript

final class AppLinksShareTests: XCTestCase {

    private func parse(_ s: String) -> AppLink? {
        guard let u = URL(string: s) else { return nil }
        return AppLink.parse(u)
    }

    // MARK: link-kind round trips

    func test_friendLink_roundTrip_https_and_customScheme() {
        let u = AppLink.friendURL(username: "jacey_s.1-x")
        XCTAssertEqual(u?.absoluteString, "https://fellowscript.com/u/jacey_s.1-x")
        XCTAssertEqual(AppLink.parse(u!), .friend(username: "jacey_s.1-x"))
        XCTAssertEqual(parse("com.fellowscript.app://u/alice"), .friend(username: "alice"))
        XCTAssertEqual(parse("https://www.fellowscript.com/u/alice/"), .friend(username: "alice"))
        XCTAssertEqual(parse("HTTPS://FELLOWSCRIPT.COM/u/alice"), .friend(username: "alice"))
    }

    func test_verseLink_roundTrip_for_every_book() {
        for (book, chapters) in AppLink.chapterCounts {
            let u = AppLink.verseURL(book: book, chapter: chapters, verse: 1)
            XCTAssertNotNil(u, book)
            XCTAssertEqual(AppLink.parse(u!), .verse(book: book, chapter: chapters, verse: 1), book)
        }
        XCTAssertEqual(AppLink.verseURL(book: "1 Samuel", chapter: 3, verse: 10)?.absoluteString,
                       "https://fellowscript.com/v/1-samuel/3/10")
        XCTAssertEqual(parse("com.fellowscript.app://v/song-of-solomon/2/4"),
                       .verse(book: "Song of Solomon", chapter: 2, verse: 4))
        XCTAssertEqual(parse("https://fellowscript.com/v/john/3/16"), .verse(book: "John", chapter: 3, verse: 16))
    }

    func test_groupLink_roundTrip() {
        let u = AppLink.groupURL(publicId: "Ab3dE6gH9k")
        XCTAssertEqual(u?.absoluteString, "https://fellowscript.com/g/Ab3dE6gH9k")
        XCTAssertEqual(AppLink.parse(u!), .group(publicId: "Ab3dE6gH9k"))
        XCTAssertEqual(parse("com.fellowscript.app://g/Ab3dE6gH9k"), .group(publicId: "Ab3dE6gH9k"))
    }

    func test_joinInviteLink_isNotParsedByAppLink_andStillWorksViaInviteLink() {
        let token = String(repeating: "a", count: 43)
        let url = URL(string: "https://fellowscript.com/join/\(token)")!
        XCTAssertNil(AppLink.parse(url))
        XCTAssertEqual(InviteLink.token(from: url), token)
        XCTAssertNil(InviteLink.token(from: URL(string: "https://fellowscript.com/u/alice")!))
    }

    // MARK: malformed / hostile rejection

    func test_malformedAndHostileURLs_areRejected() {
        let bad = [
            "http://fellowscript.com/u/alice",                       // not https
            "https://evil.com/u/alice",
            "https://fellowscript.com.evil.com/u/alice",
            "https://sub.fellowscript.com/u/alice",
            "https://user:pw@fellowscript.com/u/alice",              // userinfo
            "https://fellowscript.com:8443/u/alice",                 // port
            "https://fellowscript.com/u/alice?next=http://evil",     // query
            "https://fellowscript.com/u/alice#frag",                 // fragment
            "https://fellowscript.com/u/alice/extra",                // extra segment
            "https://fellowscript.com/u/",                           // empty
            "https://fellowscript.com/u",
            "https://fellowscript.com/u//alice",
            "https://fellowscript.com/u/al%69ce",                    // percent-encoding
            "https://fellowscript.com/u/%2e%2e",
            "https://fellowscript.com/u/..",                         // dot segment
            "https://fellowscript.com/u/.",
            "https://fellowscript.com/u/\(String(repeating: "a", count: 33))", // too long
            "https://fellowscript.com/u/al ice",
            "https://fellowscript.com/u/al\\ice",
            "https://fellowscript.com/x/alice",                      // unknown kind
            "https://fellowscript.com/",
            "ftp://fellowscript.com/u/alice",
            "javascript://fellowscript.com/u/alice",
            "other.scheme://u/alice",
            "com.fellowscript.app://u/alice/extra",
            "com.fellowscript.app://U/alice",                         // kind is case-sensitive
            "com.fellowscript.app://u",
            // group
            "https://fellowscript.com/g/Ab3dE6gH9",                  // 9
            "https://fellowscript.com/g/Ab3dE6gH9kk",                // 11
            "https://fellowscript.com/g/Ab3dE6gH9_",                 // non-alnum
            "https://fellowscript.com/g/Ab3dE6gH9k/",                // ok trailing -> handled below
            "https://fellowscript.com/g/Ab3dE6gH9k/x",
            "https://fellowscript.com/g/Ab3dE6gH9%6b",
            // verse
            "https://fellowscript.com/v/john/3",
            "https://fellowscript.com/v/john/3/16/1",
            "https://fellowscript.com/v/John/3/16",                  // not a canonical slug
            "https://fellowscript.com/v/notabook/1/1",
            "https://fellowscript.com/v/john/03/16",                 // leading zero
            "https://fellowscript.com/v/john/3/016",
            "https://fellowscript.com/v/john/0/1",
            "https://fellowscript.com/v/john/3/0",
            "https://fellowscript.com/v/john/22/1",                  // John has 21 chapters
            "https://fellowscript.com/v/john/3/177",
            "https://fellowscript.com/v/john/3/1000",
            "https://fellowscript.com/v/john/-1/1",
            "https://fellowscript.com/v/john/3/x",
        ]
        for s in bad {
            // The trailing-slash group URL is the one legal shape in this list.
            if s == "https://fellowscript.com/g/Ab3dE6gH9k/" {
                XCTAssertEqual(parse(s), .group(publicId: "Ab3dE6gH9k"))
                continue
            }
            XCTAssertNil(parse(s), "should reject: \(s)")
        }
    }

    func test_nonASCII_and_unicodeDigits_areRejected() {
        XCTAssertNil(parse("https://fellowscript.com/u/alic\u{0435}"))          // Cyrillic e
        XCTAssertNil(parse("https://fellowscript.com/g/Ab3dE6gH9\u{0661}"))      // Arabic-Indic digit
        XCTAssertNil(parse("https://fellowscript.com/v/john/\u{0663}/16"))
        XCTAssertFalse(AppLink.isValidUsername("alice\n"))
        XCTAssertFalse(AppLink.isValidPublicId("Ab3dE6gH9k\n"))
        XCTAssertFalse(AppLink.isValidUsername(""))
        XCTAssertFalse(AppLink.isValidUsername("..."))
        XCTAssertTrue(AppLink.isValidUsername("a.b"))
    }

    func test_builders_refuse_invalid_inputs() {
        XCTAssertNil(AppLink.friendURL(username: "a b"))
        XCTAssertNil(AppLink.friendURL(username: "a/b"))
        XCTAssertNil(AppLink.friendURL(username: ""))
        XCTAssertNil(AppLink.groupURL(publicId: "short"))
        XCTAssertNil(AppLink.verseURL(book: "Nonsense", chapter: 1, verse: 1))
    }

    // MARK: verse bounds

    func test_verseBounds() {
        XCTAssertTrue(AppLink.isValidVerse(book: "Psalms", chapter: 150, verse: 176))
        XCTAssertFalse(AppLink.isValidVerse(book: "Psalms", chapter: 151, verse: 1))
        XCTAssertFalse(AppLink.isValidVerse(book: "Psalms", chapter: 119, verse: 177))
        XCTAssertFalse(AppLink.isValidVerse(book: "Obadiah", chapter: 2, verse: 1))
        XCTAssertFalse(AppLink.isValidVerse(book: "Genesis", chapter: 0, verse: 1))
        XCTAssertFalse(AppLink.isValidVerse(book: "Genesis", chapter: 1, verse: 0))
        XCTAssertFalse(AppLink.isValidVerse(book: "genesis", chapter: 1, verse: 1))
        XCTAssertEqual(AppLink.chapterCounts.count, 66)
        XCTAssertNil(AppLink.slug(forBook: "Tobit"))
    }

    // MARK: note payload: title + creator + friend link only

    func test_notePayload_hasTitleCreatorAndFriendLink_only() {
        let p = SharePayloads.note(title: "Romans study", creatorUsername: "alice")
        XCTAssertNotNil(p)
        let text = p!.text
        XCTAssertTrue(text.contains("Romans study"))
        XCTAssertTrue(text.contains("alice"))
        XCTAssertTrue(text.contains("https://fellowscript.com/u/alice"))
        XCTAssertEqual(text.components(separatedBy: "\n").count, 3)
    }

    func test_noteShare_neverReadsBodyPreviewOrIds() {
        // SharePayloads.note only takes title + username, so a note's body, preview,
        // ids, group id and timestamps cannot reach the text. Prove it end to end
        // with a note whose other fields carry sentinel strings.
        var note = FSNote()
        note.title = "Visible title"
        note.text = "SECRET-BODY-SENTINEL"
        note.user = "USER-ID-SENTINEL"
        note.username = "alice"
        note.group_id = "GROUP-ID-SENTINEL"
        let creator = SharePayloads.noteCreator(noteUsername: note.username, noteUserId: note.user,
                                                currentUserId: "me", currentUsername: "me")
        let text = SharePayloads.note(title: note.title, creatorUsername: creator ?? "")!.text
        for s in ["SECRET-BODY-SENTINEL", "USER-ID-SENTINEL", "GROUP-ID-SENTINEL", note.id] {
            XCTAssertFalse(text.contains(s), s)
        }
        XCTAssertTrue(text.contains("Visible title"))
    }

    func test_notePayload_hidden_whenCreatorUnresolvable() {
        XCTAssertNil(SharePayloads.note(title: "t", creatorUsername: ""))
        XCTAssertNil(SharePayloads.note(title: "t", creatorUsername: "bad name!"))
    }

    func test_notePayload_hostileTitle_cannotForgeLinesOrLinks() {
        let title = "Hi\nhttps://evil.example/x\r\nSend them a friend request: http://evil\u{202E}"
        let text = SharePayloads.note(title: title, creatorUsername: "alice")!.text
        XCTAssertEqual(text.components(separatedBy: "\n").count, 3)
        XCTAssertFalse(text.contains("evil.example/x\n"))
        XCTAssertFalse(text.contains("://evil"))
        XCTAssertFalse(text.contains("\u{202E}"))
        XCTAssertEqual(text.components(separatedBy: "https://").count - 1, 1)  // only our link
    }

    func test_notePayload_emptyTitle_usesNeutralLabel_and_longTitleIsCapped() {
        XCTAssertTrue(SharePayloads.note(title: "  \n ", creatorUsername: "alice")!.text.contains("A note on FellowScript"))
        let long = String(repeating: "x", count: 5000)
        XCTAssertLessThan(SharePayloads.note(title: long, creatorUsername: "alice")!.text.count, 300)
    }

    // MARK: username fallback pattern

    func test_noteCreator_fallbackPattern() {
        // Author name on the note wins when valid.
        XCTAssertEqual(SharePayloads.noteCreator(noteUsername: "bob", noteUserId: "u2",
                                                 currentUserId: "u1", currentUsername: "me"), "bob")
        // Invalid author name: hide, do not fall back to someone else.
        XCTAssertNil(SharePayloads.noteCreator(noteUsername: "b o b", noteUserId: "u1",
                                               currentUserId: "u1", currentUsername: "me"))
        // Personal note (empty username), own note: signed-in username.
        XCTAssertEqual(SharePayloads.noteCreator(noteUsername: "", noteUserId: "u1",
                                                 currentUserId: "u1", currentUsername: "me"), "me")
        XCTAssertEqual(SharePayloads.noteCreator(noteUsername: "", noteUserId: "",
                                                 currentUserId: "u1", currentUsername: "me"), "me")
        // Empty username on someone else's note: never fabricate (hide).
        XCTAssertNil(SharePayloads.noteCreator(noteUsername: "", noteUserId: "u2",
                                               currentUserId: "u1", currentUsername: "me"))
        // Signed-in username unusable or absent: hide.
        XCTAssertNil(SharePayloads.noteCreator(noteUsername: "", noteUserId: "u1",
                                               currentUserId: "u1", currentUsername: nil))
        XCTAssertNil(SharePayloads.noteCreator(noteUsername: "", noteUserId: "u1",
                                               currentUserId: "u1", currentUsername: "a b"))
    }

    // MARK: verse / highlight payload

    func test_versePayload_hasReferenceTextAndLink() {
        let p = SharePayloads.verse(book: "John", chapter: 3, verse: 16, text: "For God so loved the world")
        XCTAssertEqual(p?.text, "John 3:16\nFor God so loved the world\nRead it in FellowScript: https://fellowscript.com/v/john/3/16")
    }

    func test_versePayload_rejectsBadReferenceOrEmptyText() {
        XCTAssertNil(SharePayloads.verse(book: "John", chapter: 22, verse: 1, text: "x"))
        XCTAssertNil(SharePayloads.verse(book: "Fake", chapter: 1, verse: 1, text: "x"))
        XCTAssertNil(SharePayloads.verse(book: "John", chapter: 3, verse: 16, text: " \n "))
    }

    // MARK: announcement payload + unpublished hiding

    func test_announcementPayload_allowlist() {
        let p = SharePayloads.announcement(groupName: "Tuesday Group", title: "Potluck",
                                           publishAt: "2026-10-11T12:00:00+00:00",
                                           published: true, publicId: "Ab3dE6gH9k")
        XCTAssertNotNil(p)
        let t = p!.text
        XCTAssertTrue(t.hasPrefix("Tuesday Group: Potluck"))
        XCTAssertTrue(t.contains("https://fellowscript.com/g/Ab3dE6gH9k"))
        XCTAssertFalse(t.contains("/join/"))                 // never an invite link
        XCTAssertLessThanOrEqual(t.components(separatedBy: "\n").count, 3)
    }

    func test_announcementPayload_excludesDescriptionLocationHandlesAndIds() throws {
        // Decode a full announcement with sensitive fields; the builder only takes
        // group name, title, publish_at, published and the listing id.
        let json = """
        {"id":"ANN-ID-SENTINEL","group_id":"GROUP-ID-SENTINEL","creator_id":"CREATOR-ID-SENTINEL",
         "creator_username":"HOST-NAME-SENTINEL","title":"Potluck","description":"DESCRIPTION-SENTINEL https://evil.example",
         "publish_at":"2026-10-11T12:00:00+00:00","created_at":"2026-10-10T12:00:00+00:00",
         "updated_at":"2026-10-10T12:00:00+00:00","published":true,"can_edit":false,
         "location":"123 PRIVATE-ADDRESS-SENTINEL St"}
        """
        let item = try JSONDecoder().decode(FSGroupAnnouncement.self, from: Data(json.utf8))
        let t = SharePayloads.announcement(groupName: "G", title: item.title, publishAt: item.publish_at,
                                           published: item.published, publicId: "Ab3dE6gH9k")!.text
        for s in ["ANN-ID-SENTINEL", "GROUP-ID-SENTINEL", "CREATOR-ID-SENTINEL", "HOST-NAME-SENTINEL",
                  "DESCRIPTION-SENTINEL", "PRIVATE-ADDRESS-SENTINEL", "evil.example"] {
            XCTAssertFalse(t.contains(s), s)
        }
    }

    func test_announcementPayload_unpublishedOrUnlinkable_isNil() {
        // Scheduled announcement: not shareable.
        XCTAssertNil(SharePayloads.announcement(groupName: "G", title: "T", publishAt: "",
                                                published: false, publicId: "Ab3dE6gH9k"))
        // Group with no published listing (no/invalid public id): Share hidden, no fallback.
        XCTAssertNil(SharePayloads.announcement(groupName: "G", title: "T", publishAt: "",
                                                published: true, publicId: ""))
        XCTAssertNil(SharePayloads.announcement(groupName: "G", title: "T", publishAt: "",
                                                published: true, publicId: "tooShort"))
        // Missing group name or title.
        XCTAssertNil(SharePayloads.announcement(groupName: " ", title: "T", publishAt: "",
                                                published: true, publicId: "Ab3dE6gH9k"))
        XCTAssertNil(SharePayloads.announcement(groupName: "G", title: "", publishAt: "",
                                                published: true, publicId: "Ab3dE6gH9k"))
    }

    @MainActor
    func test_announcementShareResolver_failsClosed_whenServiceCannotProvideListing() async throws {
        let json = """
        {"id":"a","group_id":"g","title":"T","description":"d","publish_at":"2026-10-11T12:00:00+00:00",
         "created_at":"2026-10-10T12:00:00+00:00","updated_at":"2026-10-10T12:00:00+00:00","published":true,"can_edit":false}
        """
        let item = try JSONDecoder().decode(FSGroupAnnouncement.self, from: Data(json.utf8))
        let appState = AppState(service: MockDataService.shared)
        appState.currentUser = FSUser(user_id: "u1", username: "me", email: "me@example.com")
        appState.isAuthenticated = true
        let p = await AnnouncementShare.payload(for: item, appState: appState)
        XCTAssertNil(p)   // no share-link capability / flag off: Share hidden, no invite fallback

        var scheduled = item
        scheduled.published = false
        let p2 = await AnnouncementShare.payload(for: scheduled, appState: appState)
        XCTAssertNil(p2)
    }

    // MARK: AppState routing: deferred until auth, confirm only

    @MainActor
    func test_handleIncomingURL_signedOut_defers_and_releasesAtSignIn() {
        let appState = AppState(service: MockDataService.shared)
        appState.isAuthenticated = false
        appState.handleIncomingURL(URL(string: "https://fellowscript.com/u/alice")!)
        XCTAssertNil(appState.pendingFriendLink)
        appState.isAuthenticated = true
        appState.releaseDeferredShareLink()
        XCTAssertEqual(appState.pendingFriendLink, PendingFriendLink(username: "alice"))
        appState.clearShareLinks()
        XCTAssertNil(appState.pendingFriendLink)
    }

    @MainActor
    func test_handleIncomingURL_signedIn_routesEachKind_and_ignoresHostile() {
        let appState = AppState(service: MockDataService.shared)
        appState.isAuthenticated = true
        appState.handleIncomingURL(URL(string: "https://fellowscript.com/g/Ab3dE6gH9k")!)
        XCTAssertEqual(appState.pendingGroupLink, PendingGroupLink(publicId: "Ab3dE6gH9k"))
        appState.handleIncomingURL(URL(string: "https://fellowscript.com/v/john/3/16")!)
        XCTAssertEqual(appState.pendingVerseLink, BibleNavTarget(book: "John", chapter: 3, verse: 16))
        appState.clearShareLinks()
        for s in ["https://evil.com/u/alice", "https://fellowscript.com/u/a%2Fb",
                  "https://fellowscript.com/v/john/99/1", "https://fellowscript.com/g/short"] {
            appState.handleIncomingURL(URL(string: s)!)
        }
        XCTAssertNil(appState.pendingFriendLink)
        XCTAssertNil(appState.pendingGroupLink)
        XCTAssertNil(appState.pendingVerseLink)
    }

    @MainActor
    func test_signedOutHostileLink_isNeverDeferred() {
        let appState = AppState(service: MockDataService.shared)
        appState.isAuthenticated = false
        appState.handleIncomingURL(URL(string: "https://evil.com/u/alice")!)
        appState.isAuthenticated = true
        appState.releaseDeferredShareLink()
        XCTAssertNil(appState.pendingFriendLink)
    }
}
