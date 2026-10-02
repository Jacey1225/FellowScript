// ExploreEntryTests.swift — task 20261001-ios-explorer-entry, step 3.
// Visibility matrix, URL building, registry wiring and copy for the iOS
// Explore entry and the owner-only Publish row.

import XCTest
import SwiftUI
@testable import FellowScript

final class ExploreEntryLogicTests: XCTestCase {
    private let host = "fellowscript.com"
    private let link = "https://fellowscript.com/#/explore"

    private func caps(browse: Bool = true, publish: Bool = false, link: String?) -> FSCapabilities {
        FSCapabilities(features: ["explorer_browse": browse, "explorer_publish": publish],
                       exploreLink: link, termsCurrent: true)
    }

    // Explore row visibility matrix
    func test_browse_visibleOnlyWhenFlagOnAndLinkValid() {
        XCTAssertEqual(ExploreEntry.browseURL(from: caps(link: link), expectedHost: host)?.absoluteString, link)
        XCTAssertNil(ExploreEntry.browseURL(from: caps(browse: false, link: link), expectedHost: host))
        XCTAssertNil(ExploreEntry.browseURL(from: caps(link: nil), expectedHost: host))
        XCTAssertNil(ExploreEntry.browseURL(from: .allOff, expectedHost: host))
        XCTAssertNil(ExploreEntry.browseURL(from: FSCapabilities(features: [:], exploreLink: link, termsCurrent: true), expectedHost: host))
    }

    func test_browse_rejectsBadLinks() {
        for bad in ["http://fellowscript.com/#/explore",
                    "https://evil.com/#/explore",
                    "https://fellowscript.com.evil.com/#/explore",
                    "https://user:pw@fellowscript.com/#/explore",
                    "https://user@fellowscript.com/#/explore",
                    "javascript:alert(1)", "ftp://fellowscript.com/", "", "   ", "//fellowscript.com/x", "/explore"] {
            XCTAssertNil(ExploreEntry.browseURL(from: caps(link: bad), expectedHost: host), "must reject \(bad)")
        }
    }

    func test_browse_hostMatchCaseInsensitive_andTrimsWhitespace() {
        XCTAssertNotNil(ExploreEntry.browseURL(from: caps(link: "https://FellowScript.COM/#/explore"), expectedHost: host))
        XCTAssertNotNil(ExploreEntry.browseURL(from: caps(link: " https://fellowscript.com/#/explore\n"), expectedHost: host))
    }

    func test_validated_failsClosedWithoutExpectedHost() {
        XCTAssertNil(ExploreEntry.validated(link, expectedHost: nil))
        XCTAssertNil(ExploreEntry.validated(link, expectedHost: ""))
    }

    func test_defaultHost_isApiBaseHost() {
        XCTAssertEqual(ExploreEntry.defaultHost, "fellowscript.com")
        XCTAssertNotNil(ExploreEntry.browseURL(from: caps(link: link)))
    }

    // Publish URL
    func test_publishURL_buildsManageFragment() {
        let c = caps(publish: true, link: link)
        XCTAssertEqual(ExploreEntry.publishURL(from: c, groupId: "g123", expectedHost: host)?.absoluteString,
                       "https://fellowscript.com/#/explore/manage?group=g123")
    }

    func test_publishURL_encodesGroupId() {
        let c = caps(publish: true, link: link)
        let u = ExploreEntry.publishURL(from: c, groupId: "a b&c=d#e/f?g+h%i", expectedHost: host)!
        XCTAssertEqual(u.absoluteString,
                       "https://fellowscript.com/#/explore/manage?group=a%20b%26c%3Dd%23e%2Ff%3Fg%2Bh%25i")
        XCTAssertEqual(URLComponents(url: u, resolvingAgainstBaseURL: false)?.host, host)
        XCTAssertNil(URLComponents(url: u, resolvingAgainstBaseURL: false)?.query)
    }

    func test_publishURL_dropsPathAndQueryOfExploreLink() {
        let c = caps(publish: true, link: "https://fellowscript.com/some/path?x=1#/explore")
        XCTAssertEqual(ExploreEntry.publishURL(from: c, groupId: "g", expectedHost: host)?.absoluteString,
                       "https://fellowscript.com/#/explore/manage?group=g")
    }

    func test_publishURL_nilWhenAnyGateFails() {
        XCTAssertNil(ExploreEntry.publishURL(from: caps(publish: false, link: link), groupId: "g", expectedHost: host))
        XCTAssertNil(ExploreEntry.publishURL(from: caps(publish: true, link: link), groupId: "", expectedHost: host))
        XCTAssertNil(ExploreEntry.publishURL(from: caps(publish: true, link: nil), groupId: "g", expectedHost: host))
        XCTAssertNil(ExploreEntry.publishURL(from: caps(publish: true, link: "http://fellowscript.com/"), groupId: "g", expectedHost: host))
        XCTAssertNil(ExploreEntry.publishURL(from: caps(publish: true, link: "https://evil.com/"), groupId: "g", expectedHost: host))
        // browse off hides publish too (link is dropped / browse gate fails)
        XCTAssertNil(ExploreEntry.publishURL(from: caps(browse: false, publish: true, link: link), groupId: "g", expectedHost: host))
    }

    // Owner-only matrix
    func test_showsPublishRow_ownerMatrix() {
        let on = caps(publish: true, link: link)
        XCTAssertTrue(ExploreEntry.showsPublishRow(on, isOwner: true, groupId: "g", expectedHost: host))
        XCTAssertFalse(ExploreEntry.showsPublishRow(on, isOwner: false, groupId: "g", expectedHost: host))
        XCTAssertFalse(ExploreEntry.showsPublishRow(caps(publish: false, link: link), isOwner: true, groupId: "g", expectedHost: host))
        XCTAssertFalse(ExploreEntry.showsPublishRow(caps(publish: true, link: nil), isOwner: true, groupId: "g", expectedHost: host))
        XCTAssertFalse(ExploreEntry.showsPublishRow(.allOff, isOwner: true, groupId: "g", expectedHost: host))
    }

    // Capabilities decode end to end: non-browse body never yields a link
    func test_decodedCapabilities_browseOffHidesEverything() throws {
        let body = #"{"features":{"explorer_browse":false,"explorer_publish":true},"links":{"explore":"https://fellowscript.com/#/explore"},"terms_current":true}"#
        let c = try JSONDecoder().decode(FSCapabilities.self, from: Data(body.utf8))
        XCTAssertNil(ExploreEntry.browseURL(from: c))
        XCTAssertNil(ExploreEntry.publishURL(from: c, groupId: "g"))
    }

    func test_decodedCapabilities_onProducesURLs() throws {
        let body = #"{"features":{"explorer_browse":true,"explorer_publish":true},"links":{"explore":"https://fellowscript.com/#/explore"},"terms_current":true}"#
        let c = try JSONDecoder().decode(FSCapabilities.self, from: Data(body.utf8))
        XCTAssertNotNil(ExploreEntry.browseURL(from: c))
        XCTAssertEqual(ExploreEntry.publishURL(from: c, groupId: "g")?.absoluteString,
                       "https://fellowscript.com/#/explore/manage?group=g")
    }

    func test_destination_identityIsURL() {
        let u = URL(string: "https://fellowscript.com/#/explore")!
        XCTAssertEqual(ExploreDestination(url: u), ExploreDestination(url: u))
        XCTAssertEqual(ExploreDestination(url: u).id, u.absoluteString)
    }
}

@MainActor
final class GroupPublishSectionTests: XCTestCase {
    private func ctx(owner: Bool, id: String = "g1") -> GroupInfoSectionContext {
        GroupInfoSectionContext(service: MockDataService.shared, groupId: id, userId: "u", isOwner: owner)
    }
    private let on = FSCapabilities(features: ["explorer_browse": true, "explorer_publish": true],
                                    exploreLink: "https://fellowscript.com/#/explore", termsCurrent: true)

    func test_registration_orderTenAndId() {
        XCTAssertEqual(GroupPublishSection.registration.id, "publish")
        XCTAssertEqual(GroupPublishSection.registration.order, 10)
        XCTAssertTrue(GroupInfoExtraSections.registry.contains { $0.id == "publish" })
    }

    func test_registry_visibleOnlyForOwnerWithFlags() {
        XCTAssertEqual(GroupInfoExtraSections.visible(capabilities: on, context: ctx(owner: true)).map(\.id), ["publish"])
        XCTAssertTrue(GroupInfoExtraSections.visible(capabilities: on, context: ctx(owner: false)).isEmpty)
        XCTAssertTrue(GroupInfoExtraSections.visible(capabilities: .allOff, context: ctx(owner: true)).isEmpty)
        let noPublish = FSCapabilities(features: ["explorer_browse": true], exploreLink: on.exploreLink, termsCurrent: true)
        XCTAssertTrue(GroupInfoExtraSections.visible(capabilities: noPublish, context: ctx(owner: true)).isEmpty)
    }

    func test_registry_orderingWithFutureSections() {
        let other = GroupInfoExtraSection(id: "threads", order: 30, isVisible: { _, _ in true },
                                          makeView: { _, _ in AnyView(EmptyView()) })
        let jrq = GroupInfoExtraSection(id: "join_requests", order: 20, isVisible: { _, _ in true },
                                        makeView: { _, _ in AnyView(EmptyView()) })
        let ids = GroupInfoExtraSections.visible([other, GroupPublishSection.registration, jrq],
                                                 capabilities: on, context: ctx(owner: true)).map(\.id)
        XCTAssertEqual(ids, ["publish", "join_requests", "threads"])
    }

    func test_makeView_buildsForOwner() {
        _ = GroupPublishSection.registration.makeView(on, ctx(owner: true))
    }

    // Apple-only interim copy constant (J13 undecided -> honest (c) wording)
    func test_publishCopy_defaultsToAppleOnlyLimitation() {
        XCTAssertEqual(PublishRowCopy.current, .appleOnlyLimitation)
        let line = PublishRowCopy.current.secondaryLine
        XCTAssertTrue(line.contains("Apple only"))
        XCTAssertTrue(line.contains("can't sign in on the website yet"))
        XCTAssertTrue(line.hasPrefix("You will sign in in your browser."))
    }

    func test_publishCopy_variantsDistinctAndNonEmpty() {
        let all: [PublishRowCopy] = [.signInInBrowser, .appleOnlyLimitation, .resetPasswordFirst]
        XCTAssertEqual(Set(all.map(\.secondaryLine)).count, 3)
        XCTAssertFalse(all.contains { $0.secondaryLine.isEmpty })
    }
}
