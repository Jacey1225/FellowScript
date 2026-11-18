// WebCheckoutTests.swift — task 20261117-web-only-payments (Option A), iOS/iPad.
// Storefront gating (US shows the web link; non-US, unknown, failed or slow detection
// do not; an active Apple plan never gets it), the server-quote model and copy
// helpers. No network, no StoreKit session: the storefront and the quote source are
// injected.

import XCTest
@testable import FellowScript

@MainActor
final class WebCheckoutTests: XCTestCase {

    // MARK: Policy

    func test_storefrontPolicy_onlyUSAAllowsWebCheckout() {
        XCTAssertTrue(WebCheckoutPolicy.storefrontAllowsWebCheckout(countryCode: "USA"))
        XCTAssertTrue(WebCheckoutPolicy.storefrontAllowsWebCheckout(countryCode: "usa"))
        for code in [nil, "", "US", "GBR", "CAN", "JPN", "KOR", "NLD", "DEU", "FRA", "AUS"] as [String?] {
            XCTAssertFalse(WebCheckoutPolicy.storefrontAllowsWebCheckout(countryCode: code), "\(String(describing: code))")
        }
    }

    func test_surface_matrix() {
        typealias P = WebCheckoutPolicy
        XCTAssertEqual(P.surface(gate: .resolving, hasActiveApplePlan: false, quoteBlockedByApple: false), .resolving)
        XCTAssertEqual(P.surface(gate: .resolving, hasActiveApplePlan: true, quoteBlockedByApple: true), .resolving)
        // Non-US / unknown: StoreKit UI, whatever else is true.
        XCTAssertEqual(P.surface(gate: .disabled, hasActiveApplePlan: false, quoteBlockedByApple: false), .storeKit)
        XCTAssertEqual(P.surface(gate: .disabled, hasActiveApplePlan: true, quoteBlockedByApple: true), .storeKit)
        // US: link unless an Apple plan is active (client knowledge or server quote).
        XCTAssertEqual(P.surface(gate: .enabled, hasActiveApplePlan: false, quoteBlockedByApple: false), .web)
        XCTAssertEqual(P.surface(gate: .enabled, hasActiveApplePlan: true, quoteBlockedByApple: false), .appleManaged)
        XCTAssertEqual(P.surface(gate: .enabled, hasActiveApplePlan: false, quoteBlockedByApple: true), .appleManaged)
    }

    func test_checkoutURL_carriesOnlySeatCount() {
        XCTAssertEqual(WebCheckoutPolicy.checkoutURL(seats: 20).absoluteString,
                       "https://fellowscript.com/#/account?subscribe=1&seats=20")
        XCTAssertEqual(WebCheckoutPolicy.checkoutURL(seats: 0).absoluteString,
                       "https://fellowscript.com/#/account?subscribe=1&seats=1")
    }

    // MARK: Gate

    private func gate(_ code: String?, timeout: TimeInterval = 3) -> WebCheckoutGate {
        WebCheckoutGate(provider: { code }, timeout: timeout, listensForUpdates: false)
    }

    func test_gate_startsResolving_thenUSIsEnabled() async {
        let g = gate("USA")
        XCTAssertEqual(g.state, .resolving)
        XCTAssertFalse(g.isEnabled, "no link before the storefront is known")
        await g.refresh()
        XCTAssertEqual(g.state, .enabled)
        XCTAssertTrue(g.isEnabled)
    }

    func test_gate_nonUS_unknown_areDisabled() async {
        for code in ["GBR", "CAN", "JPN", nil] as [String?] {
            let g = gate(code)
            await g.refresh()
            XCTAssertEqual(g.state, .disabled, "\(String(describing: code))")
            XCTAssertFalse(g.isEnabled)
        }
    }

    func test_gate_slowDetection_timesOutToDisabled() async {
        let g = WebCheckoutGate(provider: {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return "USA"
        }, timeout: 0.1, listensForUpdates: false)
        await g.refresh()
        XCTAssertEqual(g.state, .disabled, "a lookup that does not answer in time counts as non-US")
    }

    func test_gate_storefrontChange_reevaluates_neverSticky() async {
        let g = gate("GBR")
        await g.refresh()
        XCTAssertFalse(g.isEnabled)
        g.apply(countryCode: "USA")
        XCTAssertTrue(g.isEnabled)
        g.apply(countryCode: nil)
        XCTAssertFalse(g.isEnabled, "a later unknown answer must turn the link off again")
    }

    func test_uiTestingStorefront_argument() {
        XCTAssertNil(WebCheckoutGate.uiTestingStorefront(arguments: ["x"]))
        XCTAssertEqual(WebCheckoutGate.uiTestingStorefront(arguments: ["UI-TESTING"]), "GBR")
        XCTAssertEqual(WebCheckoutGate.uiTestingStorefront(arguments: ["UI-TESTING", "UI-TESTING-STOREFRONT-USA"]), "USA")
    }

    // MARK: Quote decode + copy

    private func decode(_ json: String) throws -> FSSeatQuote {
        try JSONDecoder().decode(FSSeatQuote.self, from: Data(json.utf8))
    }

    func test_quoteDecodes_serverShape() throws {
        let q = try decode("""
        {"seats":20,"unit_cents":500,"discount_percent":10,"discount_start_seats":2,"total_cents":9000,
         "currency":"usd","min_seats":1,"max_seats":100,"legacy":false,"blocked":false,"blocked_reason":null}
        """)
        XCTAssertEqual(q.total_cents, 9000)
        XCTAssertEqual(q.max_seats, 100)
        XCTAssertFalse(q.blocked)
        XCTAssertEqual(WebCheckoutFormat.price(cents: 9000), "$90.00")
        XCTAssertEqual(WebCheckoutFormat.perSeatSentence(q), "$5 per seat, 10% off from 2 seats.")
        XCTAssertEqual(WebCheckoutFormat.spokenPrice(seats: 20, cents: 9000), "20 seats, 90 dollars per month")
    }

    func test_quoteDecodes_blockedAppleCaller() throws {
        let q = try decode("""
        {"seats":1,"unit_cents":500,"discount_percent":10,"discount_start_seats":2,"total_cents":null,
         "currency":"usd","min_seats":1,"max_seats":100,"legacy":false,"blocked":true,"blocked_reason":"apple_subscription_active"}
        """)
        XCTAssertTrue(q.blocked)
        XCTAssertNil(q.total_cents)
    }

    func test_quoteMissingRequiredField_throws_neverDefaultsAPrice() {
        XCTAssertThrowsError(try decode(#"{"seats":1,"total_cents":500}"#))
    }

    func test_legacyQuote_hasNoPerSeatSentence() throws {
        let q = try decode("""
        {"seats":5,"unit_cents":500,"discount_percent":10,"discount_start_seats":2,"total_cents":2025,
         "currency":"usd","min_seats":1,"max_seats":100,"legacy":true,"blocked":false}
        """)
        XCTAssertNil(WebCheckoutFormat.perSeatSentence(q))
    }

    func test_oneSeatPrice_isFiveDollars_notTheRetired499() {
        XCTAssertEqual(WebCheckoutFormat.price(cents: 500), "$5.00")
        XCTAssertEqual(WebCheckoutFormat.spokenPrice(seats: 1, cents: 500), "1 seat, 5 dollars per month")
    }

    // MARK: Quote model

    private func quote(seats: Int, total: Int? = nil, blocked: Bool = false) -> FSSeatQuote {
        FSSeatQuote(seats: seats, unit_cents: 500, discount_percent: 10, discount_start_seats: 2,
                    total_cents: blocked ? nil : (total ?? seats * 450), min_seats: 1, max_seats: 100, blocked: blocked)
    }

    private func waitFor(_ cond: @autoclosure () -> Bool, timeout: TimeInterval = 2) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func test_model_loadsQuote_andClampsToServerBounds() async {
        let m = WebCheckoutQuoteModel(debounceMilliseconds: 0)
        m.configure { [self] n in quote(seats: n) }
        m.request(seats: 1, immediate: true)
        await waitFor(m.phase == .loaded)
        XCTAssertEqual(m.totalCents, 450)
        XCTAssertEqual(m.minSeats, 1)
        XCTAssertEqual(m.maxSeats, 100)
        XCTAssertEqual(m.clamped(500), 100)
        XCTAssertEqual(m.clamped(0), 1)
    }

    func test_model_blockedQuote_marksAppleBlocked_andHasNoTotal() async {
        let m = WebCheckoutQuoteModel(debounceMilliseconds: 0)
        m.configure { [self] n in quote(seats: n, blocked: true) }
        m.request(seats: 1, immediate: true)
        await waitFor(m.phase == .loaded)
        XCTAssertTrue(m.blockedByApple)
        XCTAssertNil(m.totalCents)
        XCTAssertEqual(WebCheckoutPolicy.surface(gate: .enabled, hasActiveApplePlan: false,
                                                 quoteBlockedByApple: m.blockedByApple), .appleManaged)
    }

    func test_model_failure_keepsLastGoodQuote_andNeverFabricates() async {
        struct Boom: Error {}
        let m = WebCheckoutQuoteModel(debounceMilliseconds: 0)
        var fail = false
        m.configure { [self] n in if fail { throw Boom() }; return quote(seats: n) }
        m.request(seats: 2, immediate: true)
        await waitFor(m.phase == .loaded)
        fail = true
        m.request(seats: 3, immediate: true)
        await waitFor(m.phase == .failed)
        XCTAssertEqual(m.phase, .failed)
        XCTAssertEqual(m.quote?.seats, 2, "the previous good quote stays; nothing is invented for 3")

        let fresh = WebCheckoutQuoteModel(debounceMilliseconds: 0)
        fresh.configure { _ in throw Boom() }
        fresh.request(seats: 1, immediate: true)
        await waitFor(fresh.phase == .failed)
        XCTAssertNil(fresh.totalCents, "no quote means no price (UI says: See price on the website.)")
    }

    func test_model_staleRequestIsCancelled_lastWins() async {
        let m = WebCheckoutQuoteModel(debounceMilliseconds: 50)
        m.configure { [self] n in quote(seats: n) }
        m.request(seats: 5)
        m.request(seats: 7)
        m.request(seats: 20)
        await waitFor(m.phase == .loaded)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(m.quote?.seats, 20)
        XCTAssertEqual(m.seats, 20)
    }
}
