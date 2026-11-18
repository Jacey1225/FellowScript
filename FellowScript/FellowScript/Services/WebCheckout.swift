// WebCheckout.swift — task 20261117-web-only-payments (Option A), iOS/iPad.
//
// In the United States App Store storefront only, the app may offer a button that
// opens the website checkout (Stripe) in the system browser (App Review Guideline
// 3.1.1(a) does not require IAP there). Every other storefront keeps the existing
// StoreKit flow with no link, no website mention and no price comparison.
//
// Three small pieces, all pure or injectable so they are unit tested:
//   WebCheckoutPolicy  storefront code -> allowed, and which purchase UI to show
//   WebCheckoutGate    resolves the App Store storefront; fails closed
//   FSSeatQuote / WebCheckoutQuoteModel  server price (GET /subscriptions/quote);
//                      the app never computes a price itself.

import Foundation
import Combine
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Policy (pure)

enum WebCheckoutPurchaseSurface: Equatable {
    /// Storefront not resolved yet: render a reserved-height placeholder.
    case resolving
    /// US storefront, no Apple plan: "Subscribe on the web".
    case web
    /// Non-US or unknown storefront: the existing StoreKit purchase UI, unchanged.
    case storeKit
    /// US storefront but the user has an active Apple plan: no purchase UI at all
    /// (no double billing); manage it in Apple Settings.
    case appleManaged
}

enum WebCheckoutPolicy {
    /// StoreKit 2 reports ISO 3166-1 alpha-3 codes ("USA").
    static let usStorefrontCode = "USA"

    /// Fail closed: only an exact US code allows the web link. nil, empty or any
    /// other code (including an unexpected alpha-2 "US") is treated as non-US.
    static func storefrontAllowsWebCheckout(countryCode: String?) -> Bool {
        guard let code = countryCode else { return false }
        return code.uppercased() == usStorefrontCode
    }

    static func surface(gate: WebCheckoutGate.State,
                        hasActiveApplePlan: Bool,
                        quoteBlockedByApple: Bool) -> WebCheckoutPurchaseSurface {
        switch gate {
        case .resolving: return .resolving
        case .disabled:  return .storeKit
        case .enabled:   return (hasActiveApplePlan || quoteBlockedByApple) ? .appleManaged : .web
        }
    }

    /// Website checkout link. No tokens or ids: the user signs in on the web.
    static func checkoutURL(seats: Int) -> URL {
        let n = max(1, seats)
        return URL(string: "https://fellowscript.com/#/account?subscribe=1&seats=\(n)")!
    }

    /// Existing-plan management on the web (US only).
    static let manageURL = URL(string: "https://fellowscript.com/#/account")!
}

// MARK: - Storefront gate

@MainActor
final class WebCheckoutGate: ObservableObject {
    enum State: Equatable { case resolving, enabled, disabled }

    /// Starts resolving on first touch, so the answer is usually ready before a purchase
    /// surface appears.
    static let shared: WebCheckoutGate = { let g = WebCheckoutGate(); g.start(); return g }()

    @Published private(set) var state: State = .resolving
    var isEnabled: Bool { state == .enabled }

    typealias StorefrontProvider = @Sendable () async -> String?
    private let provider: StorefrontProvider
    private let timeout: TimeInterval
    private let listensForUpdates: Bool
    private var started = false
    private var tasks: [Task<Void, Never>] = []

    /// UI tests pass `UI-TESTING-STOREFRONT-<CODE>`; under `UI-TESTING` without it the
    /// storefront is non-US so the existing StoreKit UI tests keep their meaning.
    /// Debug builds only: a release build never honours a launch argument, so the
    /// storefront can't be forced to the US from outside the app.
    static func uiTestingStorefront(arguments: [String]) -> String? {
        #if DEBUG
        guard arguments.contains("UI-TESTING") else { return nil }
        let prefix = "UI-TESTING-STOREFRONT-"
        if let arg = arguments.first(where: { $0.hasPrefix(prefix) }) {
            return String(arg.dropFirst(prefix.count))
        }
        return "GBR"
        #else
        return nil
        #endif
    }

    init(provider: StorefrontProvider? = nil, timeout: TimeInterval = 3, listensForUpdates: Bool = true) {
        if let provider {
            self.provider = provider
            self.listensForUpdates = listensForUpdates
        } else if let forced = Self.uiTestingStorefront(arguments: ProcessInfo.processInfo.arguments) {
            self.provider = { forced }
            self.listensForUpdates = false
        } else {
            self.provider = { await Storefront.current?.countryCode }
            self.listensForUpdates = listensForUpdates
        }
        self.timeout = timeout
    }

    /// Begin resolving and keep the answer current. Safe to call repeatedly.
    func start() {
        guard !started else { return }
        started = true
        tasks.append(Task { [weak self] in await self?.refresh() })
        guard listensForUpdates else { return }
        tasks.append(Task { [weak self] in
            for await storefront in Storefront.updates {
                self?.apply(countryCode: storefront.countryCode)
            }
        })
        #if canImport(UIKit)
        tasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.willEnterForegroundNotification) {
                await self?.refresh()
            }
        })
        #endif
    }

    /// Re-reads the storefront. A lookup that does not answer within `timeout`
    /// counts as unknown, which is non-US.
    func refresh() async {
        let provider = self.provider
        let timeout = self.timeout
        let code: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { await provider() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        apply(countryCode: code)
    }

    func apply(countryCode: String?) {
        state = WebCheckoutPolicy.storefrontAllowsWebCheckout(countryCode: countryCode) ? .enabled : .disabled
    }

    /// Suspends until the first answer (at most the timeout plus a moment).
    func waitUntilResolved() async {
        start()
        while state == .resolving && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

}

// MARK: - Server quote

/// GET /subscriptions/quote?seats=N. Advisory only: checkout re-prices on the server.
struct FSSeatQuote: Decodable, Equatable {
    var seats: Int
    var unit_cents: Int
    var discount_percent: Int
    var discount_start_seats: Int?
    /// nil when the server blocked the quote (Apple-billed caller).
    var total_cents: Int?
    var currency: String
    var min_seats: Int
    var max_seats: Int
    var legacy: Bool
    var blocked: Bool
    var blocked_reason: String?

    enum CodingKeys: String, CodingKey {
        case seats, unit_cents, discount_percent, discount_start_seats, total_cents, currency
        case min_seats, max_seats, legacy, blocked, blocked_reason
    }

    init(seats: Int, unit_cents: Int, discount_percent: Int, discount_start_seats: Int? = nil,
         total_cents: Int?, currency: String = "usd", min_seats: Int, max_seats: Int,
         legacy: Bool = false, blocked: Bool = false, blocked_reason: String? = nil) {
        self.seats = seats; self.unit_cents = unit_cents; self.discount_percent = discount_percent
        self.discount_start_seats = discount_start_seats; self.total_cents = total_cents
        self.currency = currency; self.min_seats = min_seats; self.max_seats = max_seats
        self.legacy = legacy; self.blocked = blocked; self.blocked_reason = blocked_reason
    }

    /// Required fields throw (the caller shows "See price on the website", never a
    /// made-up price); the optional extras default to their safe value.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seats = try c.decode(Int.self, forKey: .seats)
        unit_cents = try c.decode(Int.self, forKey: .unit_cents)
        discount_percent = try c.decode(Int.self, forKey: .discount_percent)
        discount_start_seats = try c.decodeIfPresent(Int.self, forKey: .discount_start_seats)
        total_cents = try c.decodeIfPresent(Int.self, forKey: .total_cents)
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "usd"
        min_seats = try c.decode(Int.self, forKey: .min_seats)
        max_seats = try c.decode(Int.self, forKey: .max_seats)
        legacy = try c.decodeIfPresent(Bool.self, forKey: .legacy) ?? false
        blocked = try c.decodeIfPresent(Bool.self, forKey: .blocked) ?? false
        blocked_reason = try c.decodeIfPresent(String.self, forKey: .blocked_reason)
    }
}

enum WebCheckoutFormat {
    private static func formatter(fractionDigits: Int?) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        if let d = fractionDigits { f.minimumFractionDigits = d; f.maximumFractionDigits = d }
        return f
    }

    /// "$90.00" from cents.
    static func price(cents: Int) -> String {
        formatter(fractionDigits: 2).string(from: NSNumber(value: Double(cents) / 100)) ?? ""
    }

    /// "$5" for whole dollars, "$4.99" otherwise.
    static func compactPrice(cents: Int) -> String {
        formatter(fractionDigits: cents % 100 == 0 ? 0 : 2).string(from: NSNumber(value: Double(cents) / 100)) ?? ""
    }

    /// "$5 per seat, 10% off from 2 seats." built only from quote fields; nil when the
    /// quote describes a legacy plan or lacks the discount start.
    static func perSeatSentence(_ q: FSSeatQuote) -> String? {
        guard !q.legacy else { return nil }
        let base = "\(compactPrice(cents: q.unit_cents)) per seat"
        guard q.discount_percent > 0, let start = q.discount_start_seats else { return base + "." }
        return "\(base), \(q.discount_percent)% off from \(start) seats."
    }

    /// "20 seats, 90 dollars per month" for VoiceOver.
    static func spokenPrice(seats: Int, cents: Int) -> String {
        let dollars = Double(cents) / 100
        let amount = cents % 100 == 0 ? "\(Int(dollars))" : String(format: "%.2f", dollars)
        return "\(seats) seat\(seats == 1 ? "" : "s"), \(amount) dollars per month"
    }
}

// MARK: - Quote model

@MainActor
final class WebCheckoutQuoteModel: ObservableObject {
    enum Phase: Equatable { case idle, loading, loaded, failed }

    @Published private(set) var phase: Phase = .idle
    /// Last good quote (kept while a newer one loads, shown dimmed).
    @Published private(set) var quote: FSSeatQuote?
    @Published private(set) var blockedByApple = false
    @Published var seats: Int = 1

    private var fetch: ((Int) async throws -> FSSeatQuote)?
    private var task: Task<Void, Never>?
    private let debounce: UInt64

    init(debounceMilliseconds: UInt64 = 300) { self.debounce = debounceMilliseconds * 1_000_000 }

    func configure(service: DataServiceProtocol) { fetch = { try await service.fetchSeatQuote(seats: $0) } }
    /// Test seam: any async quote source.
    func configure(fetch: @escaping (Int) async throws -> FSSeatQuote) { self.fetch = fetch }

    var minSeats: Int? { quote?.min_seats }
    var maxSeats: Int? { quote?.max_seats }
    var totalCents: Int? { quote?.blocked == true ? nil : quote?.total_cents }

    /// Clamps to the bounds of the last good quote (none yet: leaves the value).
    func clamped(_ n: Int) -> Int {
        guard let lo = minSeats, let hi = maxSeats else { return max(1, n) }
        return min(max(n, lo), hi)
    }

    /// Requests a quote for `n` seats. `immediate` skips the debounce (first load).
    /// A newer request cancels a stale one; a failure keeps the previous good quote.
    func request(seats n: Int, immediate: Bool = false) {
        guard let fetch else { return }
        let wanted = clamped(n)
        seats = wanted
        task?.cancel()
        phase = .loading
        let delay = immediate ? 0 : debounce
        task = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled else { return }
            do {
                let q = try await fetch(wanted)
                guard !Task.isCancelled, let self else { return }
                self.quote = q
                self.blockedByApple = q.blocked
                self.phase = .loaded
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.phase = .failed
            }
        }
    }

}
