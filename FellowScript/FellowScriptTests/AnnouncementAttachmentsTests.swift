// AnnouncementAttachmentsTests.swift — testing gate for task
// 20261009-announcements-advanced, part E (links, gallery, event payments, RSVP).
//
// Covers: optional-field decoding (absent keys while flags are off, old payloads),
// draft payload rules (nothing new sent unless changed AND flag on), client-side
// validation mirroring the server caps, flag gating of every form row, RSVP
// through the real view model against StubURLProtocol (success, full/409
// rollback-safe, cache untouched on failure), link display helpers (IDN host),
// SFSafariViewController-only link opening (source pin: no WKWebView), the payment
// disclaimer, and accessibility pins.

import XCTest
import SwiftUI
@testable import FellowScript

@MainActor
final class AnnouncementAttachmentsTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }
    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }
    override func setUp() {
        super.setUp()
        StubURLProtocol.resetRequestLog()
        StubURLProtocol.stubStatusCode = 200
    }

    // MARK: helpers

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
    private func decode(_ extra: String) throws -> FSGroupAnnouncement {
        let json = """
        {"id":"a","group_id":"g","creator_id":"u","creator_username":"ann","title":"T","description":"D",
         "banner_url":null,"publish_at":"2026-01-01T00:00:00+00:00","created_at":"2026-01-01T00:00:00+00:00",
         "updated_at":"2026-01-01T00:00:00+00:00","published":true,"can_edit":true\(extra)}
        """
        return try JSONDecoder().decode(FSGroupAnnouncement.self, from: Data(json.utf8))
    }
    private func emptyDraft() -> AnnouncementExtrasDraft { AnnouncementExtrasDraft(from: nil) }
    private func apply(_ d: AnnouncementExtrasDraft, original: FSGroupAnnouncement? = nil,
                       links: Bool = true, gallery: Bool = true, payments: Bool = true, rsvp: Bool = true) -> [String: Any] {
        var out = FSAnnouncementDraft(title: "t", description: "d")
        d.apply(to: &out, original: original, links: links, gallery: gallery, payments: payments, rsvp: rsvp)
        return out.jsonObject
    }
    private let newKeys = ["links", "gallery_keys", "is_event", "payment_handles", "capacity"]

    // MARK: decoding

    func testOldPayloadWithoutPartEKeysDecodesToNil() throws {
        let a = try decode("")
        XCTAssertNil(a.links); XCTAssertNil(a.gallery); XCTAssertNil(a.is_event)
        XCTAssertNil(a.payment_handles); XCTAssertNil(a.capacity)
        XCTAssertNil(a.rsvp_count); XCTAssertNil(a.rsvp_joined)
    }

    func testFullPartEPayloadDecodes() throws {
        let a = try decode("""
        ,"links":[{"url":"https://example.com/a","label":"Sign up"},{"url":"https://b.org"}],
         "gallery":[{"key":"k1","url":"https://cdn/x.jpg"},{"key":"k2","url":null}],
         "is_event":true,"payment_handles":[{"provider":"venmo","handle":"@ann"}],
         "capacity":12,"rsvp_count":3,"rsvp_joined":true
        """)
        XCTAssertEqual(a.links?.count, 2)
        XCTAssertEqual(a.links?.first?.label, "Sign up")
        XCTAssertNil(a.links?.last?.label)
        XCTAssertEqual(a.gallery?.map(\.key), ["k1", "k2"])
        XCTAssertNil(a.gallery?.last?.url)
        XCTAssertEqual(a.is_event, true)
        XCTAssertEqual(a.payment_handles?.first, FSPaymentHandle(provider: "venmo", handle: "@ann"))
        XCTAssertEqual(a.capacity, 12); XCTAssertEqual(a.rsvp_count, 3); XCTAssertEqual(a.rsvp_joined, true)
    }

    func testNullPartEKeysDecode() throws {
        let a = try decode(#","links":null,"gallery":null,"is_event":null,"payment_handles":null,"capacity":null,"rsvp_count":null,"rsvp_joined":null"#)
        XCTAssertNil(a.links); XCTAssertNil(a.capacity); XCTAssertNil(a.is_event)
    }

    func testEmptyCollectionsDecodeAsEmpty() throws {
        let a = try decode(#","links":[],"gallery":[],"payment_handles":[]"#)
        XCTAssertEqual(a.links?.isEmpty, true)
        XCTAssertEqual(a.gallery?.isEmpty, true)
    }

    // MARK: payload: keys absent when nothing changed / flags off

    func testUnchangedDraftSendsNoPartEKeys() {
        let json = apply(emptyDraft())
        for k in newKeys { XCTAssertNil(json[k], "\(k) must be omitted when nothing changed") }
    }

    func testAllFlagsOffSendsNoPartEKeysEvenWithFilledDraft() {
        var d = emptyDraft()
        d.links = [.init(url: "example.com", label: "x")]
        d.isEvent = true; d.handles["venmo"] = "@ann"
        d.rsvpOn = true; d.capacity = 5
        let json = apply(d, links: false, gallery: false, payments: false, rsvp: false)
        for k in newKeys { XCTAssertNil(json[k], "\(k) must not be sent while its flag is off") }
    }

    func testOnlyEnabledFlagKeysAreSent() {
        var d = emptyDraft()
        d.links = [.init(url: "example.com")]
        d.rsvpOn = true; d.capacity = 7
        let json = apply(d, links: true, gallery: false, payments: false, rsvp: false)
        XCTAssertNotNil(json["links"])
        XCTAssertNil(json["capacity"], "rsvp flag off")
    }

    func testLinksPayloadIsNormalizedAndLabelOmittedWhenEmpty() throws {
        var d = emptyDraft()
        d.links = [.init(url: "example.com/x", label: ""), .init(url: " https://b.org ", label: " Hi ")]
        let arr = try XCTUnwrap(apply(d)["links"] as? [[String: Any]])
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr[0]["url"] as? String, "https://example.com/x")
        XCTAssertNil(arr[0]["label"])
        XCTAssertEqual(arr[1]["label"] as? String, "Hi")
    }

    func testBlankAndInvalidLinkRowsAreNotSent() {
        var d = emptyDraft()
        d.links = [.init(url: "   "), .init(url: "javascript:alert(1)")]
        XCTAssertTrue(d.cleanedLinks.isEmpty)
        // changed vs. an empty original? No: cleaned list equals original (empty), so nothing is sent.
        XCTAssertNil(apply(d)["links"])
    }

    func testClearingExistingLinksSendsEmptyArray() throws {
        let orig = try decode(#","links":[{"url":"https://example.com"}]"#)
        let d = AnnouncementExtrasDraft(from: orig)
        var cleared = d; cleared.links = []
        let json = apply(cleared, original: orig)
        XCTAssertEqual((json["links"] as? [Any])?.count, 0)
    }

    func testUnchangedEditSendsNothingNew() throws {
        let orig = try decode("""
        ,"links":[{"url":"https://example.com/a","label":"L"}],"gallery":[{"key":"k1","url":"https://c/x"}],
         "is_event":true,"payment_handles":[{"provider":"venmo","handle":"@ann"}],"capacity":9
        """)
        let json = apply(AnnouncementExtrasDraft(from: orig), original: orig)
        for k in newKeys { XCTAssertNil(json[k], "\(k) unchanged on edit must be omitted") }
    }

    func testGalleryKeysSentOnlyWhenChangedAndClearsWithEmptyArray() throws {
        let orig = try decode(#","gallery":[{"key":"k1","url":"https://c/x"},{"key":"k2","url":"https://c/y"}]"#)
        var d = AnnouncementExtrasDraft(from: orig)
        d.gallery.removeLast()
        XCTAssertEqual(apply(d, original: orig)["gallery_keys"] as? [String], ["k1"])
        d.gallery.removeAll()
        XCTAssertEqual((apply(d, original: orig)["gallery_keys"] as? [String])?.count, 0)
    }

    func testEventOffSendsFalseAndClearsHandles() throws {
        let orig = try decode(#","is_event":true,"payment_handles":[{"provider":"venmo","handle":"@ann"}]"#)
        var d = AnnouncementExtrasDraft(from: orig)
        d.isEvent = false
        let json = apply(d, original: orig)
        XCTAssertEqual(json["is_event"] as? Bool, false)
        XCTAssertEqual((json["payment_handles"] as? [Any])?.count, 0, "handles not carried while not an event")
    }

    func testHandlesSentWithProviderAndTrimmed() throws {
        var d = emptyDraft()
        d.isEvent = true
        d.handles["venmo"] = "  @ann "
        d.handles["zelle"] = ""
        let json = apply(d)
        XCTAssertEqual(json["is_event"] as? Bool, true)
        let hs = try XCTUnwrap(json["payment_handles"] as? [[String: String]])
        XCTAssertEqual(hs, [["provider": "venmo", "handle": "@ann"]])
    }

    func testCapacityClampedAndNullWhenRsvpTurnedOff() throws {
        var d = emptyDraft(); d.rsvpOn = true; d.capacity = 100_000
        XCTAssertEqual(apply(d)["capacity"] as? Int, 9999)
        d.capacity = 0
        XCTAssertEqual(apply(d)["capacity"] as? Int, 1)
        let orig = try decode(#","capacity":10"#)
        var off = AnnouncementExtrasDraft(from: orig); off.rsvpOn = false
        XCTAssertTrue(apply(off, original: orig)["capacity"] is NSNull, "turning RSVP off clears with explicit null")
    }

    // MARK: client-side validation

    func testLinkSchemeValidation() {
        XCTAssertNotNil(AnnouncementLinkSafety.parse("https://example.com/a?b=1"))
        XCTAssertNotNil(AnnouncementLinkSafety.parse("http://example.com"))
        XCTAssertEqual(AnnouncementLinkSafety.parse("example.com/x")?.absoluteString, "https://example.com/x", "missing scheme -> https")
        for bad in ["javascript:alert(1)", "data:text/html,hi", "ftp://example.com", "file:///etc/passwd",
                    "mailto:a@b.com", "tel:5551234", "sms:5551234", "intent://x", "fellowscript://x",
                    "https://user:pw@example.com", "https://exa mple.com", "https://localhost", "https://", "", "   ",
                    "https://example.com/\u{0007}", "https://.example.com", "https://example.com."] {
            XCTAssertNil(AnnouncementLinkSafety.parse(bad), "should reject \(bad.debugDescription)")
        }
    }

    func testLinkLengthCap() {
        let ok = "https://example.com/" + String(repeating: "a", count: 500 - "https://example.com/".count)
        XCTAssertEqual(ok.count, 500)
        XCTAssertNotNil(AnnouncementLinkSafety.parse(ok))
        XCTAssertNil(AnnouncementLinkSafety.parse(ok + "a"), "501 chars rejected")
    }

    func testLinkCountCapIs5AndFormHidesAddButtonAtCap() throws {
        XCTAssertEqual(AnnouncementExtrasLimits.maxLinks, 5)
        let form = try readSource("FellowScript/Chat/AnnouncementExtrasForm.swift")
        XCTAssertTrue(form.contains("extras.links.count < AnnouncementExtrasLimits.maxLinks"))
    }

    func testLinkErrorAndBlockingError() {
        var d = emptyDraft()
        d.links = [.init(url: "javascript:alert(1)")]
        XCTAssertNotNil(d.linkError(d.links[0]))
        XCTAssertNotNil(d.blockingError(links: true, payments: true))
        XCTAssertNil(d.blockingError(links: false, payments: true), "link flag off -> link errors ignored")
        d.links = [.init(url: "example.com"), .init(url: "")]
        XCTAssertNil(d.blockingError(links: true, payments: true), "blank rows are not errors")
    }

    func testLabelAndHandleLimitsMatchServer() throws {
        XCTAssertEqual(AnnouncementExtrasLimits.maxLabelLength, 60)
        XCTAssertEqual(AnnouncementExtrasLimits.maxHandleLength, 64)
        XCTAssertEqual(AnnouncementExtrasLimits.maxGallery, 6)
        XCTAssertEqual(AnnouncementExtrasLimits.capacityRange, 1...9999)
        XCTAssertEqual(AnnouncementExtrasLimits.maxLinkLength, 500)
        // Server caps are the source of truth: parse them out of the validator module.
        let py = try String(contentsOf: projectRoot.deletingLastPathComponent().appendingPathComponent("api/backend/interactions/announcement_extras.py"), encoding: .utf8)
        XCTAssertTrue(py.contains("500") && py.contains("60") && py.contains("9999"))
    }

    func testHandleFormatsAndCardNumberRejection() {
        func err(_ s: String) -> String? {
            var d = emptyDraft(); d.isEvent = true; d.handles["venmo"] = s
            return d.handleError(.venmo)
        }
        XCTAssertNil(err("@ann_smith"))
        XCTAssertNil(err("ann@example.com"))
        XCTAssertNil(err("555-123-4567"), "10-digit phone is fine")
        XCTAssertNil(err(""))
        XCTAssertNotNil(err("4111 1111 1111 1111"), "card number")
        XCTAssertNotNil(err("4111111111111111"))
        XCTAssertNotNil(err("1234567890123"), "13 digits")
        XCTAssertNotNil(err(String(repeating: "a", count: 65)), "too long")
    }

    func testPaymentErrorIgnoredWhenNotEventOrFlagOff() {
        var d = emptyDraft(); d.handles["venmo"] = "4111111111111111"
        XCTAssertNil(d.blockingError(links: true, payments: true), "not an event: handles not sent")
        d.isEvent = true
        XCTAssertNotNil(d.blockingError(links: true, payments: true))
        XCTAssertNil(d.blockingError(links: true, payments: false), "payments flag off")
    }

    func testProvidersAreExactlyServerEnum() throws {
        XCTAssertEqual(Set(AnnouncementPaymentProvider.allCases.map(\.rawValue)), ["venmo", "cashapp", "paypal", "zelle"])
        let py = try String(contentsOf: projectRoot.deletingLastPathComponent().appendingPathComponent("api/backend/interactions/announcement_extras.py"), encoding: .utf8)
        for p in AnnouncementPaymentProvider.allCases { XCTAssertTrue(py.contains("\"\(p.rawValue)\""), "\(p.rawValue) in server") }
    }

    func testGalleryCapAndGalleryRowHidesPickerAtSix() throws {
        let form = try readSource("FellowScript/Chat/AnnouncementExtrasForm.swift")
        XCTAssertTrue(form.contains("n < AnnouncementExtrasLimits.maxGallery"))
        XCTAssertTrue(form.contains("AnnouncementExtrasLimits.maxGallery - n"), "picker selection limit shrinks with existing photos")
        XCTAssertTrue(form.contains("extras.gallery.count < AnnouncementExtrasLimits.maxGallery"), "loop stops at cap")
    }

    func testGalleryJpegDownscalesLongEdgeTo1600() async throws {
        let size = CGSize(width: 4000, height: 3000)
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1
        let src = UIGraphicsImageRenderer(size: size, format: fmt).image { c in
            UIColor.systemTeal.setFill(); c.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
        let jpeg = await AnnouncementGalleryProcessor.jpeg(from: src)
        let data = try XCTUnwrap(jpeg)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
        let img = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(max(img.size.width * img.scale, img.size.height * img.scale), 1600, accuracy: 1)
        let junk = await AnnouncementGalleryProcessor.jpeg(from: Data("not an image".utf8))
        XCTAssertNil(junk)
    }

    func testCountBadgeOnlyCountsEnabledFlags() throws {
        let orig = try decode("""
        ,"links":[{"url":"https://example.com"}],"gallery":[{"key":"k","url":null}],"is_event":true,"capacity":4
        """)
        let d = AnnouncementExtrasDraft(from: orig)
        XCTAssertEqual(d.count(links: true, gallery: true, payments: true, rsvp: true), 4)
        XCTAssertEqual(d.count(links: false, gallery: false, payments: false, rsvp: false), 0)
        XCTAssertEqual(d.count(links: true, gallery: false, payments: false, rsvp: true), 2)
    }

    // MARK: flag gating of form rows

    func testFlagNamesMatchServer() throws {
        XCTAssertEqual(AnnouncementExtrasFlag.links, "announcement_links")
        XCTAssertEqual(AnnouncementExtrasFlag.gallery, "announcement_gallery")
        XCTAssertEqual(AnnouncementExtrasFlag.payments, "announcement_payments")
        XCTAssertEqual(AnnouncementExtrasFlag.rsvp, "announcement_rsvp")
        let flags = try String(contentsOf: projectRoot.deletingLastPathComponent().appendingPathComponent("api/backend/interactions/flags.py"), encoding: .utf8)
        for n in [AnnouncementExtrasFlag.links, AnnouncementExtrasFlag.gallery, AnnouncementExtrasFlag.payments, AnnouncementExtrasFlag.rsvp] { XCTAssertTrue(flags.contains("\"\(n)\""), n) }
    }

    func testAllFlagsOffCapabilitiesEnableNothing() {
        let off = FSCapabilities.allOff
        for n in [AnnouncementExtrasFlag.links, AnnouncementExtrasFlag.gallery, AnnouncementExtrasFlag.payments, AnnouncementExtrasFlag.rsvp] { XCTAssertFalse(off.isEnabled(n), n) }
        let on = FSCapabilities(features: [AnnouncementExtrasFlag.rsvp: true], exploreLink: nil, termsCurrent: true)
        XCTAssertTrue(on.isEnabled(AnnouncementExtrasFlag.rsvp))
        XCTAssertFalse(on.isEnabled(AnnouncementExtrasFlag.payments))
    }

    func testEachFormRowAndSectionIsGatedBySourcePin() throws {
        let host = try readSource("FellowScript/Chat/GroupAnnouncementFormView.swift")
        XCTAssertTrue(host.contains("private var extrasOn: Bool { linksOn || galleryOn || paymentsOn || rsvpOn }"))
        XCTAssertTrue(host.contains("if extrasOn {\n                            AnnouncementExtrasSection("), "whole section absent when all four are off")
        XCTAssertTrue(host.contains("capabilities.isEnabled(AnnouncementExtrasFlag.links)"))
        XCTAssertTrue(host.contains("capabilities.isEnabled(AnnouncementExtrasFlag.gallery)"))
        XCTAssertTrue(host.contains("capabilities.isEnabled(AnnouncementExtrasFlag.payments)"))
        XCTAssertTrue(host.contains("capabilities.isEnabled(AnnouncementExtrasFlag.rsvp)"))
        XCTAssertTrue(host.contains("if extrasOn {\n            extras.apply("), "payload only touched when a flag is on")
        XCTAssertTrue(host.contains("extrasOn ? extras.blockingError"), "validation ignored when all off")
        let form = try readSource("FellowScript/Chat/AnnouncementExtrasForm.swift")
        for row in ["if linksOn { linksRow }", "if galleryOn { galleryRow }", "if paymentsOn { paymentsRow }", "if rsvpOn { spotsRow }"] {
            XCTAssertTrue(form.contains(row), row)
        }
    }

    func testExtrasSectionIsCollapsedByDefaultAndLast() throws {
        let form = try readSource("FellowScript/Chat/AnnouncementExtrasForm.swift")
        XCTAssertTrue(form.contains("@State private var open = false"))
        XCTAssertTrue(form.contains("Add extras (optional)"))
        let host = try readSource("FellowScript/Chat/GroupAnnouncementFormView.swift")
        let publish = try XCTUnwrap(host.range(of: "if canReschedule { publishField }"))
        let extras = try XCTUnwrap(host.range(of: "AnnouncementExtrasSection("))
        XCTAssertLessThan(publish.lowerBound, extras.lowerBound, "extras come after the core fields")
    }

    func testDetailBlocksHiddenWhenEmpty() throws {
        let src = try readSource("FellowScript/Chat/AnnouncementExtrasDetail.swift")
        for line in ["if !gallery.isEmpty { galleryBlock }", "if !links.isEmpty { linksBlock }",
                     "if !handles.isEmpty { paymentsBlock }", "if let cap = item.capacity { rsvpBlock(capacity: cap) }"] {
            XCTAssertTrue(src.contains(line), line)
        }
        XCTAssertTrue(src.contains("guard item.is_event == true else { return [] }"), "handles only shown for events")
        XCTAssertTrue(src.contains("AnnouncementPaymentProvider(rawValue: h.provider)"), "unknown providers skipped")
    }

    func testDetailRenderSmokeWithAndWithoutExtras() throws {
        let plain = try decode("")
        let full = try decode("""
        ,"links":[{"url":"https://example.com/a","label":"Sign up"}],"gallery":[{"key":"k1","url":"https://cdn.example.com/x.jpg"}],
         "is_event":true,"payment_handles":[{"provider":"venmo","handle":"@ann"},{"provider":"bogus","handle":"x"}],
         "capacity":2,"rsvp_count":2,"rsvp_joined":false,"published":true
        """)
        for item in [plain, full] {
            let host = UIHostingController(rootView: AnnouncementExtrasDetail(item: item, textColor: .white, onRSVP: nil)
                .environment(\.dynamicTypeSize, .accessibility3))
            host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 1200)
            host.view.layoutIfNeeded()
            XCTAssertGreaterThanOrEqual(host.sizeThatFits(in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude)).height, 0)
        }
        let emptyH = UIHostingController(rootView: AnnouncementExtrasDetail(item: plain, textColor: .white, onRSVP: nil))
        let fullH = UIHostingController(rootView: AnnouncementExtrasDetail(item: full, textColor: .white, onRSVP: nil))
        let w = CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude)
        XCTAssertEqual(emptyH.sizeThatFits(in: w).height, 0, accuracy: 0.5, "no extras renders nothing")
        XCTAssertGreaterThan(fullH.sizeThatFits(in: w).height, 50)
    }

    // MARK: link host display / IDN

    func testDisplayHostStripsWwwAndLowercases() {
        XCTAssertEqual(AnnouncementLinkSafety.displayHost(URL(string: "https://WWW.Example.com/a")!), "example.com")
        XCTAssertEqual(AnnouncementLinkSafety.displayHost(URL(string: "https://sub.example.org")!), "sub.example.org")
    }

    func testLookalikeRiskForIDNAndPunycode() {
        XCTAssertFalse(AnnouncementLinkSafety.isLookalikeRisk(host: "example.com"))
        XCTAssertTrue(AnnouncementLinkSafety.isLookalikeRisk(host: "exаmple.com"), "cyrillic a")
        XCTAssertTrue(AnnouncementLinkSafety.isLookalikeRisk(host: "xn--exmple-cua.com"))
        XCTAssertTrue(AnnouncementLinkSafety.isLookalikeRisk(host: "sub.xn--80ak6aa92e.com"))
        XCTAssertFalse(AnnouncementLinkSafety.isLookalikeRisk(host: "my-xn.example.com"))
    }

    func testIDNLinkParsesAndIsFlaggedNotRejected() throws {
        let url = try XCTUnwrap(AnnouncementLinkSafety.parse("https://münchen.de/x"))
        // Whatever form URL normalization yields, the display helper must flag a non-ASCII or punycode host.
        let host = AnnouncementLinkSafety.displayHost(url)
        XCTAssertTrue(AnnouncementLinkSafety.isLookalikeRisk(host: host), "host \(host) must be flagged")
    }

    // MARK: SFSafariViewController only

    func testLinksOpenOnlyInSafariViewControllerNoWebView() throws {
        let files = ["FellowScript/Chat/AnnouncementExtras.swift", "FellowScript/Chat/AnnouncementExtrasDetail.swift",
                     "FellowScript/Chat/AnnouncementExtrasForm.swift", "FellowScript/Chat/GroupAnnouncementDetailView.swift",
                     "FellowScript/Chat/GroupAnnouncementFormView.swift", "FellowScript/Chat/GroupAnnouncementWidgetView.swift",
                     "FellowScript/Chat/GroupAnnouncementsView.swift"]
        for f in files {
            let s = try readSource(f)
            XCTAssertFalse(s.contains("WKWebView"), "\(f) must not use WKWebView")
            XCTAssertFalse(s.contains("import WebKit"), "\(f) must not import WebKit")
            XCTAssertFalse(s.contains("UIApplication.shared.open"), "\(f) must open links through the Safari sheet only")
            XCTAssertFalse(s.contains("openURL"), "\(f) must open links through the Safari sheet only")
        }
        let detail = try readSource("FellowScript/Chat/AnnouncementExtrasDetail.swift")
        XCTAssertTrue(detail.contains("exploreSafariSheet($safari)"))
        XCTAssertTrue(detail.contains("AnnouncementLinkSafety.parse(l.url)"), "server URL re-validated before use")
        let explore = try readSource("FellowScript/Chat/ExploreEntry.swift")
        XCTAssertTrue(explore.contains("SFSafariViewController(url: url"))
        XCTAssertFalse(explore.contains("WKWebView"))
    }

    func testServerLinkWithBadSchemeIsDroppedFromDetail() throws {
        // Detail only renders links that pass parse(); javascript:/data: from a hostile payload never reach the sheet.
        XCTAssertNil(AnnouncementLinkSafety.parse("javascript:alert(document.cookie)"))
        XCTAssertNil(AnnouncementLinkSafety.parse("data:text/html;base64,PHNjcmlwdD4="))
        let hostile = try decode(#","links":[{"url":"javascript:alert(1)"},{"url":"data:text/html,x"}]"#)
        let host = UIHostingController(rootView: AnnouncementExtrasDetail(item: hostile, textColor: .white, onRSVP: nil))
        XCTAssertEqual(host.sizeThatFits(in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude)).height, 0, accuracy: 0.5)
    }

    // MARK: payment disclaimer

    func testPaymentDisclaimerPresentInFormAndDetail() throws {
        XCTAssertTrue(AnnouncementExtrasLimits.paymentDisclaimer.contains("outside FellowScript"))
        XCTAssertTrue(AnnouncementExtrasLimits.paymentDisclaimer.contains("never handles money"))
        let form = try readSource("FellowScript/Chat/AnnouncementExtrasForm.swift")
        XCTAssertTrue(form.contains("Text(AnnouncementExtrasLimits.paymentDisclaimer)"))
        let detail = try readSource("FellowScript/Chat/AnnouncementExtrasDetail.swift")
        XCTAssertTrue(detail.contains("AnnouncementExtrasLimits.paymentDisclaimer"))
    }

    func testPaymentHandlesAreDisplayOnlyNeverLinks() throws {
        let detail = try readSource("FellowScript/Chat/AnnouncementExtrasDetail.swift")
        let start = try XCTUnwrap(detail.range(of: "private var paymentsBlock"))
        let end = try XCTUnwrap(detail.range(of: "// ── RSVP"))
        let block = String(detail[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(block.contains("Link("), "no deep links to payment apps")
        XCTAssertFalse(block.contains("safari ="), "payment handle never opens a URL")
        XCTAssertTrue(block.contains("textSelection") || block.contains("UIPasteboard"), "copyable text")
    }

    // MARK: RSVP via the real view model

    private func vm() -> GroupAnnouncementsViewModel {
        GroupAnnouncementsViewModel(service: NetworkService.shared, groupId: "g-\(UUID().uuidString)", userId: "u-\(UUID().uuidString)")
    }
    private func itemJSON(count: Int, joined: Bool, capacity: Int = 3) -> String {
        """
        {"id":"a1","group_id":"g","creator_id":"u","creator_username":"ann","title":"T","description":"D",
         "banner_url":null,"publish_at":"2026-01-01T00:00:00+00:00","created_at":"2026-01-01T00:00:00+00:00",
         "updated_at":"2026-01-01T00:00:00+00:00","published":true,"can_edit":false,
         "capacity":\(capacity),"rsvp_count":\(count),"rsvp_joined":\(joined)}
        """
    }
    private func page(_ item: String) -> Data {
        #"{"announcements":[\#(item)],"truncated":false,"gate":null}"#.data(using: .utf8)!
    }

    func testRsvpJoinPostsAndReplacesCachedItem() async throws {
        StubURLProtocol.stubBody = page(itemJSON(count: 1, joined: false))
        let vm = vm(); await vm.load()
        let original = try XCTUnwrap(vm.items.first)
        StubURLProtocol.resetRequestLog()
        StubURLProtocol.stubBody = itemJSON(count: 2, joined: true).data(using: .utf8)!
        let updated = try await vm.rsvp(original, join: true)
        XCTAssertEqual(updated.rsvp_count, 2); XCTAssertEqual(updated.rsvp_joined, true)
        XCTAssertEqual(vm.items.first?.rsvp_count, 2, "cached item refreshed from server truth")
        let reqs = StubURLProtocol.requestLog.filter { $0.path.hasSuffix("/announcements/a1/rsvp") }
        XCTAssertEqual(reqs.map(\.method), ["POST"])
    }

    func testRsvpLeaveUsesDelete() async throws {
        StubURLProtocol.stubBody = page(itemJSON(count: 2, joined: true))
        let vm = vm(); await vm.load()
        let original = try XCTUnwrap(vm.items.first)
        StubURLProtocol.resetRequestLog()
        StubURLProtocol.stubBody = itemJSON(count: 1, joined: false).data(using: .utf8)!
        let updated = try await vm.rsvp(original, join: false)
        XCTAssertEqual(updated.rsvp_joined, false)
        XCTAssertEqual(StubURLProtocol.requestLog.filter { $0.path.hasSuffix("/rsvp") }.map(\.method), ["DELETE"])
    }

    func testRsvpFullThrowsAndLeavesCachedItemUntouched() async throws {
        StubURLProtocol.stubBody = page(itemJSON(count: 3, joined: false))
        let vm = vm(); await vm.load()
        let original = try XCTUnwrap(vm.items.first)
        StubURLProtocol.stubStatusCode = 409
        StubURLProtocol.stubBody = #"{"detail":"This event is full"}"#.data(using: .utf8)!
        do {
            _ = try await vm.rsvp(original, join: true)
            XCTFail("a full event must throw so the optimistic count rolls back")
        } catch {
            // expected
        }
        XCTAssertEqual(vm.items.first?.rsvp_count, 3, "failed RSVP must not change cached counts")
        XCTAssertEqual(vm.items.first?.rsvp_joined, false)
        XCTAssertFalse(vm.removedFromGroup)
    }

    func testRsvpServerErrorThrowsAndNotMemberMarksRemoved() async throws {
        StubURLProtocol.stubBody = page(itemJSON(count: 0, joined: false))
        let vm = vm(); await vm.load()
        let original = try XCTUnwrap(vm.items.first)
        StubURLProtocol.stubStatusCode = 500
        StubURLProtocol.stubBody = #"{"detail":"boom"}"#.data(using: .utf8)!
        do { _ = try await vm.rsvp(original, join: true); XCTFail("expected throw") } catch {}
        XCTAssertEqual(vm.items.first?.rsvp_count, 0)
        StubURLProtocol.stubStatusCode = 403
        StubURLProtocol.stubBody = #"{"detail":"Not a member of this group"}"#.data(using: .utf8)!
        do { _ = try await vm.rsvp(original, join: true); XCTFail("expected throw") } catch {}
        XCTAssertTrue(vm.removedFromGroup)
    }

    func testRsvpViewIsOptimisticWithRollbackSourcePin() throws {
        let src = try readSource("FellowScript/Chat/AnnouncementExtrasDetail.swift")
        XCTAssertTrue(src.contains("override = (count: max(0, count + (joined ? -1 : 1)), joined: !joined)"), "optimistic flip")
        XCTAssertTrue(src.contains("override = before"), "rollback on failure")
        XCTAssertTrue(src.contains("guard let onRSVP, !rsvpBusy else { return }"), "double tap guarded")
        XCTAssertTrue(src.contains(".disabled(rsvpBusy || full)"))
        XCTAssertTrue(src.contains("item.published"), "no RSVP on scheduled items")
        XCTAssertTrue(src.contains("RSVP only. It doesn't change your group membership."))
    }

    func testRsvpNeverTouchesMembership() throws {
        let svc = try readSource("FellowScript/Services/NetworkService+Announcements.swift")
        let start = try XCTUnwrap(svc.range(of: "func rsvpAnnouncement(userId: String, groupId: String, announcementId: String, join: Bool) async throws -> FSGroupAnnouncement {"))
        let body = String(svc[start.lowerBound...].prefix(600))
        XCTAssertTrue(body.contains("/rsvp"))
        XCTAssertFalse(body.contains("join_group") || body.contains("/members"))
    }

    // MARK: accessibility pins

    func testAccessibilityPins() throws {
        let form = try readSource("FellowScript/Chat/AnnouncementExtrasForm.swift")
        for s in [".accessibilityLabel(title)", ".accessibilityHint(isOpen ? \"Collapses\" : \"Expands\")", "expanded", "collapsed",
                  "accessibilityReduceMotion", "withAnimation(reduceMotion ? nil", "Remove link", "Link address", "Link label",
                  "Remove photo", "Gallery photo", "handle\")", "Number of spots", "minHeight: 44", "typeSize.isAccessibilitySize"] {
            XCTAssertTrue(form.contains(s), "form missing a11y pin: \(s)")
        }
        let detail = try readSource("FellowScript/Chat/AnnouncementExtrasDetail.swift")
        for s in [".accessibilityAddTraits(.isHeader)", ".accessibilityAddTraits(.isLink)", ".accessibilityHint(\"Opens in Safari\")",
                  "Photo \\(idx + 1) of", "Close photo viewer", "Cancel your RSVP", "going\\(joined ? \", including you\"", "minHeight: 44"] {
            XCTAssertTrue(detail.contains(s), "detail missing a11y pin: \(s)")
        }
    }
}
