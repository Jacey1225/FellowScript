// PriceCutPricingTests.swift -- task 20261001-subscription-price-cut, testing step 5.
// The iOS fallback table must match the server table (api/schemas/subscription.py
// GROUP_PRICE_CENTS), and plan price labels must show cents (the old integer
// division rendered 499 as "$4").

import XCTest
@testable import FellowScript

final class PriceCutPricingTests: XCTestCase {
    private let serverTable: [Int: Int] = [
        1: 499, 2: 810, 3: 1215, 4: 1620, 5: 2025, 6: 2430, 7: 2835, 8: 3240,
    ]

    func testFallbackTableMatchesServerTable() {
        XCTAssertEqual(AccountView.fallbackPriceCents, serverTable)
    }

    func testPriceLabelShowsCents() throws {
        for (count, cents) in serverTable {
            let json = "{\"id\":\"s\",\"user_id\":\"u\",\"plan_type\":\"group\",\"provider\":\"apple\","
                + "\"status\":\"active\",\"price_cents\":\(cents),\"max_members\":\(count)}"
            let sub = try JSONDecoder().decode(FSSubscription.self, from: Data(json.utf8))
            XCTAssertEqual(sub.priceLabel, String(format: "$%d.%02d", cents / 100, cents % 100))
        }
    }
}
