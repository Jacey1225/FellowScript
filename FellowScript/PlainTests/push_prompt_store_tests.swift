// push_prompt_store_tests.swift -- task 20261105-push-prompt-sheet.
// Plain-script tests (no XCTest, no simulator). Run with:
//   FellowScript/PlainTests/run_push_prompt_tests.sh
// Compiles FellowScript/Onboarding/PushPromptStore.swift together with this file.

import Foundation
import UserNotifications

var failures = 0
var checks = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    checks += 1
    if !cond() { failures += 1; print("FAIL (line \(line)): \(msg)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String, line: Int = #line) {
    checks += 1
    if a != b { failures += 1; print("FAIL (line \(line)): \(msg): got \(a), expected \(b)") }
}

let day: TimeInterval = 86_400
var clock = Date(timeIntervalSince1970: 1_800_000_000)

func makeStore() -> (PushPromptStore, UserDefaults, String) {
    let suite = "PushPromptStorePlain-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    var s = PushPromptStore(defaults: d)
    s.now = { clock }
    return (s, d, suite)
}

// MARK: primer cadence 7 / 14 / cap 3
do {
    clock = Date(timeIntervalSince1970: 1_800_000_000)
    let (s, d, suite) = makeStore(); defer { d.removePersistentDomain(forName: suite) }
    check(s.isEligible(for: .primer), "fresh install eligible for primer")
    check(!s.isEligible(for: .hidden), "hidden never eligible")
    s.recordAsk(for: .primer)
    eq(s.askCount, 1, "ask count 1")
    check(!s.isEligible(for: .primer), "snoozed immediately after ask 1")
    clock += 7 * day - 1
    check(!s.isEligible(for: .primer), "still snoozed 1s before 7 days")
    clock += 1
    check(s.isEligible(for: .primer), "eligible at exactly 7 days")
    s.recordAsk(for: .primer)
    eq(s.askCount, 2, "ask count 2")
    clock += 14 * day - 1
    check(!s.isEligible(for: .primer), "snoozed 1s before 14 days after ask 2")
    clock += 1
    check(s.isEligible(for: .primer), "eligible at 14 days after ask 2")
    s.recordAsk(for: .primer)
    eq(s.askCount, 3, "ask count 3")
    clock += 365 * day
    check(!s.isEligible(for: .primer), "capped after 3 primer asks, even a year later")
    check(s.isEligible(for: .openSettings), "primer cap does not consume denied cap (snooze long past)")
}

// MARK: denied cadence 7 / 14, cap 2
do {
    clock = Date(timeIntervalSince1970: 1_800_000_000)
    let (s, d, suite) = makeStore(); defer { d.removePersistentDomain(forName: suite) }
    check(s.isEligible(for: .openSettings), "fresh eligible for denied")
    s.recordAsk(for: .openSettings)
    eq(s.deniedAskCount, 1, "denied count 1")
    clock += 7 * day - 1
    check(!s.isEligible(for: .openSettings), "denied snoozed before 7d")
    clock += 1
    check(s.isEligible(for: .openSettings), "denied eligible at 7d")
    s.recordAsk(for: .openSettings)
    eq(s.deniedAskCount, 2, "denied count 2")
    clock += 14 * day
    check(!s.isEligible(for: .openSettings), "denied capped after 2")
    eq(s.askCount, 0, "denied asks do not touch primer count")
}

// MARK: hidden recordAsk is a no-op
do {
    let (s, d, suite) = makeStore(); defer { d.removePersistentDomain(forName: suite) }
    s.recordAsk(for: .hidden)
    eq(s.askCount, 0, "hidden ask no count")
    check(s.isEligible(for: .primer), "hidden ask sets no snooze")
}

// MARK: reset
do {
    let (s, d, suite) = makeStore(); defer { d.removePersistentDomain(forName: suite) }
    s.recordAsk(for: .primer); s.recordAsk(for: .openSettings)
    s.clearCounters()
    eq(s.askCount, 0, "reset primer count")
    eq(s.deniedAskCount, 0, "reset denied count")
    check(s.isEligible(for: .primer) && s.isEligible(for: .openSettings), "reset clears snooze")
    for k in [PushPromptStore.askCountKey, PushPromptStore.deniedAskCountKey, PushPromptStore.nextEligibleAtKey] {
        check(d.object(forKey: k) == nil, "key \(k) removed")
    }
}

// MARK: persistence across store instances
do {
    let (s, d, suite) = makeStore(); defer { d.removePersistentDomain(forName: suite) }
    s.recordAsk(for: .primer)
    var s2 = PushPromptStore(defaults: d); s2.now = { clock }
    eq(s2.askCount, 1, "persisted across instances")
    check(!s2.isEligible(for: .primer), "snooze persisted")
}

// MARK: status mapping
typealias S = UNAuthorizationStatus
// .ephemeral is unavailable when compiling for macOS; build it from its raw value (4) when the SDK allows.
let grantedStatuses: [S] = [S.authorized, S.provisional] + (S(rawValue: 4).map { [$0] } ?? [])
eq(PushPromptMapping.kind(for: .notDetermined, pushDeferred: true), .primer, "notDetermined+deferred -> primer")
eq(PushPromptMapping.kind(for: .notDetermined, pushDeferred: false), .hidden, "notDetermined+not deferred -> hidden (no race)")
for deferred in [true, false] {
    eq(PushPromptMapping.kind(for: .denied, pushDeferred: deferred), .openSettings, "denied -> openSettings (deferred=\(deferred))")
    for s in grantedStatuses {
        eq(PushPromptMapping.kind(for: s, pushDeferred: deferred), .hidden, "granted \(s.rawValue) hidden")
    }
    // fail closed: unknown raw values
    for raw in [99, -1, 6, 1000] {
        if let unknown = S(rawValue: raw) {
            eq(PushPromptMapping.kind(for: unknown, pushDeferred: deferred), .hidden, "unknown raw \(raw) hidden")
            check(!PushPromptMapping.isGranted(unknown), "unknown raw \(raw) not granted")
        }
    }
}
for s in grantedStatuses { check(PushPromptMapping.isGranted(s), "granted \(s.rawValue)") }
check(!PushPromptMapping.isGranted(.notDetermined), "notDetermined not granted")
check(!PushPromptMapping.isGranted(.denied), "denied not granted")

// MARK: suppression precedence
do {
    let (s, d, suite) = makeStore(); defer { d.removePersistentDomain(forName: suite) }
    let none = PushPromptSuppression()
    check(!none.isSuppressed, "default not suppressed")
    eq(PushPromptMapping.resolve(status: .notDetermined, pushDeferred: true, suppression: none, store: s), .primer, "resolve primer")
    eq(PushPromptMapping.resolve(status: .denied, pushDeferred: false, suppression: none, store: s), .openSettings, "resolve denied")

    let flags: [(String, WritableKeyPath<PushPromptSuppression, Bool>)] = [
        ("postTourPromptOwed", \.postTourPromptOwed),
        ("postTourAnsweredThisSession", \.postTourAnsweredThisSession),
        ("inCall", \.inCall), ("readingSession", \.readingSession),
        ("loadingScreen", \.loadingScreen), ("otherPresentationActive", \.otherPresentationActive),
    ]
    for (name, kp) in flags {
        var sup = PushPromptSuppression(); sup[keyPath: kp] = true
        check(sup.isSuppressed, "\(name) suppresses")
        eq(PushPromptMapping.resolve(status: .notDetermined, pushDeferred: true, suppression: sup, store: s), .hidden, "\(name) hides primer")
        eq(PushPromptMapping.resolve(status: .denied, pushDeferred: false, suppression: sup, store: s), .hidden, "\(name) hides denied")
    }
    // suppression must not consume an ask
    eq(s.askCount, 0, "resolve never records asks")
    // granted + no suppression stays hidden
    eq(PushPromptMapping.resolve(status: .authorized, pushDeferred: true, suppression: none, store: s), .hidden, "authorized hidden")
    // cap/snooze hides even when unsuppressed
    s.recordAsk(for: .primer)
    eq(PushPromptMapping.resolve(status: .notDetermined, pushDeferred: true, suppression: none, store: s), .hidden, "snoozed primer hidden")
    // unknown status hidden even with everything clear
    if let unk = S(rawValue: 99) {
        eq(PushPromptMapping.resolve(status: unk, pushDeferred: true, suppression: none, store: s), .hidden, "unknown status hidden")
    }
}

print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
