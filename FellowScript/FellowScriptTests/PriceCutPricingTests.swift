// PriceCutPricingTests.swift -- task 20261001-subscription-price-cut, testing step 5.
// Plan price labels must show cents (the old integer division rendered 499 as "$4").
// Existing plans keep their stored price_cents, so the legacy 1-8 values stay here
// as test data only (the app no longer carries a fallback price table).

import XCTest
@testable import FellowScript

final class PriceCutPricingTests: XCTestCase {
    private let serverTable: [Int: Int] = [
        1: 499, 2: 810, 3: 1215, 4: 1620, 5: 2025, 6: 2430, 7: 2835, 8: 3240,
    ]

    // The hardcoded iOS fallback price table was removed (task 20261117-web-only-payments):
    // US web prices come from GET /subscriptions/quote, other storefronts show StoreKit's
    // own localized price. Nothing in the app mirrors the server table any more.

    func testPriceLabelShowsCents() throws {
        for (count, cents) in serverTable {
            let json = "{\"id\":\"s\",\"user_id\":\"u\",\"plan_type\":\"group\",\"provider\":\"apple\","
                + "\"status\":\"active\",\"price_cents\":\(cents),\"max_members\":\(count)}"
            let sub = try JSONDecoder().decode(FSSubscription.self, from: Data(json.utf8))
            XCTAssertEqual(sub.priceLabel, String(format: "$%d.%02d", cents / 100, cents % 100))
        }
    }
}
