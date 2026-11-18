// WebCheckoutCopyTests.swift — task 20261117-web-only-payments. Source-level guards
// for the Apple-policy split: web wording lives only in the US-gated files, the
// hardcoded price fallbacks are gone, and the StoreKit surfaces carry no website
// text (App Review Guideline 3.1.1(a): no link or call to action outside the US).

import XCTest
@testable import FellowScript

final class WebCheckoutCopyTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        // #filePath: .../FellowScriptTests/WebCheckoutCopyTests.swift
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("FellowScript/" + relative), encoding: .utf8)
    }

    func test_noHardcodedFallbackPrices() throws {
        let sub = try source("Account/AccountView+Subscription.swift")
        XCTAssertFalse(sub.contains("fallbackPriceCents"))
        XCTAssertFalse(sub.contains("fallbackPriceLabel"))
        let post = try source("Onboarding/PostTourPromptViews.swift")
        XCTAssertFalse(post.contains("fallbackPrice"))
        XCTAssertFalse(post.contains("$4.99"))
    }

    func test_webWording_neverInStoreKitOnlyFiles() throws {
        for f in ["Services/StoreKitManager.swift", "Account/InviteCodeViewModel.swift"] {
            let s = try source(f).lowercased()
            XCTAssertFalse(s.contains("subscribe on the web"), f)
            XCTAssertFalse(s.contains("fellowscript.com/#/account"), f)
        }
    }

    func test_pickerBranchHasNoWebCopy() throws {
        let sub = try source("Account/AccountView+Subscription.swift")
        let start = try XCTUnwrap(sub.range(of: "func memberCountPickerRow()"))
        let end = try XCTUnwrap(sub.range(of: "func seatManagementRow"))
        let picker = String(sub[start.lowerBound..<end.lowerBound]).lowercased()
        XCTAssertFalse(picker.contains("website"))
        XCTAssertFalse(picker.contains("on the web"))
        XCTAssertFalse(picker.contains("fellowscript.com/#/account"))
    }

    func test_webButtonCopy() {
        XCTAssertEqual(WebCheckoutPolicy.checkoutURL(seats: 3).host, "fellowscript.com")
    }
}
