// HomeMessageStore.swift -- cache + fail-soft state for the Home headline
// (task 20261002-home-announcement-headline).
//
// `text` is the announcement currently shown, or nil for the fallback
// "Welcome Back, <name>!". Initial value is the cached last-good message if it
// is under an hour old, else nil -- so the first frame never waits on the
// network and never shows a spinner. A failed refresh never clears the cache;
// a successful `message: null` does (admin turned it off).

import Combine
import Foundation

@MainActor
final class HomeMessageStore: ObservableObject {
    static let maxCacheAge: TimeInterval = 3600
    static let textKey = "homeMessage.cachedText"
    static let dateKey = "homeMessage.cachedAt"

    @Published private(set) var text: String?

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        self.text = Self.cached(defaults: defaults, now: now())
    }

    static func cached(defaults: UserDefaults, now: Date) -> String? {
        guard let t = HomeMessageText.clean(defaults.string(forKey: textKey)),
              let at = defaults.object(forKey: dateKey) as? Date else { return nil }
        let age = now.timeIntervalSince(at)
        return (age >= 0 && age < maxCacheAge) ? t : nil
    }

    /// Fetch off the critical path. Any thrown error keeps the current display.
    func refresh(service: Any?) async {
        guard let svc = service as? HomeMessageService else { return }
        do {
            apply(try await svc.fetchHomeMessage())
        } catch {
            // Keep whatever is shown (and cached); re-evaluate cache age only.
            if text != nil, Self.cached(defaults: defaults, now: now()) == nil { text = nil }
        }
    }

    func apply(_ fetched: String?) {
        if let fetched {
            defaults.set(fetched, forKey: Self.textKey)
            defaults.set(now(), forKey: Self.dateKey)
        } else {
            defaults.removeObject(forKey: Self.textKey)
            defaults.removeObject(forKey: Self.dateKey)
        }
        if text != fetched { text = fetched }
    }
}
