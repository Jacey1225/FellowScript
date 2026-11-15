// ActivityCalendarViewsTests.swift -- task 20261114-activity-calendar, step 8.
// Home card + month screen behaviour (hosted in a real UIWindow), the
// check-in code outside Home staying intact, and (when the screens directory
// exists on this Mac) dark-mode screenshots at 375 and 420 pt.

import XCTest
import SwiftUI
import UIKit
import ViewInspector
@testable import FellowScript

@MainActor
final class ActivityCalendarViewsTests: XCTestCase {
    static let screensDir = "/Users/jaceysimpson/Vscode/FellowScript/.claude/pipeline/20261114-activity-calendar/screens"

    // today in the stored timezone, same call the views make
    private func today(_ tz: String? = "UTC") -> CalDay { ActivityCalendarMath.today(timeZoneId: tz) }

    /// A month filled with data for the month containing `t`, including the
    /// last day with three icons and the first with one.
    private func fullMonth(_ y: Int, _ m: Int) -> FSActivityMonth {
        var days: [String: [FSActivityKind]] = [:]
        let n = ActivityCalendarMath.daysIn(year: y, month: m)
        for d in 1...n {
            let key = CalDay(y: y, m: m, d: d).key
            switch d % 4 {
            case 0: days[key] = [.chat, .note, .bible]
            case 1: days[key] = [.chat]
            case 2: days[key] = [.note, .bible]
            default: break
            }
        }
        days[CalDay(y: y, m: m, d: n).key] = [.chat, .note, .bible]
        if n >= 30 { days[CalDay(y: y, m: m, d: 30).key] = [.chat, .note, .bible] }
        return FSActivityMonth(year: y, month: m, timezone: "UTC", days: days)
    }

    private func store(_ months: [FSActivityMonth]) async -> ActivityCalendarStore {
        let s = ActivityCalendarStore(userId: "test-\(UUID().uuidString)") { y, m in
            guard let hit = months.first(where: { $0.year == y && $0.month == m }) else {
                return FSActivityMonth(year: y, month: m, timezone: "UTC", days: [:])
            }
            return hit
        }
        for m in months { try? await s.refresh(year: m.year, month: m.month) }
        return s
    }

    private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat = 900) -> (UIWindow, UIHostingController<AnyView>) {
        let vc = UIHostingController(rootView: AnyView(view.environment(\.colorScheme, .dark)))
        vc.overrideUserInterfaceStyle = .dark
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        w.overrideUserInterfaceStyle = .dark
        w.rootViewController = vc
        w.makeKeyAndVisible()
        vc.view.setNeedsLayout(); vc.view.layoutIfNeeded()
        return (w, vc)
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 400_000_000) }

    private func accessibilityNodes(_ root: UIView) -> [NSObject] {
        var out: [NSObject] = []
        func walk(_ o: NSObject) {
            if let els = o.accessibilityElements as? [NSObject], !els.isEmpty { els.forEach(walk); return }
            let n = o.accessibilityElementCount()
            if n != NSNotFound && n > 0 { for i in 0..<n { if let c = o.accessibilityElement(at: i) as? NSObject { walk(c) } }; return }
            if o.isAccessibilityElement { out.append(o) }
            if let v = o as? UIView { v.subviews.forEach(walk) }
        }
        walk(root)
        return out
    }

    private func render(_ vc: UIViewController, to name: String) throws {
        guard FileManager.default.fileExists(atPath: Self.screensDir) else { throw XCTSkip("screens dir missing") }
        let v = vc.view!
        let r = UIGraphicsImageRenderer(bounds: v.bounds)
        let img = r.image { _ in v.drawHierarchy(in: v.bounds, afterScreenUpdates: true) }
        try img.pngData()!.write(to: URL(fileURLWithPath: "\(Self.screensDir)/\(name).png"))
    }

    // MARK: Home card (ViewInspector)

    func test_homeCard_isOneButton_withLabelHintAndOpens() async throws {
        let t = today()
        let s = await store([fullMonth(t.y, t.m)])
        var opened = 0
        let card = ActivityCalendarHomeCard(store: s, timeZoneId: "UTC") { opened += 1 }
        let root = try card.inspect()
        let n = s.activeDays(year: t.y, month: t.m)!
        XCTAssertEqual(try root.find(ViewType.Button.self).accessibilityLabel().string(), "Your month. \(activeDaysText(n)).")
        XCTAssertEqual(try root.find(ViewType.Button.self).accessibilityHint().string(), "Opens the full month.")
        try root.find(ViewType.Button.self).tap()
        XCTAssertEqual(opened, 1)
    }

    func test_homeCard_zeroActiveDays_orNoData_hasNoCountInLabel() async throws {
        let t = today()
        let empty = await store([FSActivityMonth(year: t.y, month: t.m, timezone: "UTC", days: [:])])
        let c1 = ActivityCalendarHomeCard(store: empty, timeZoneId: "UTC") {}
        XCTAssertEqual(try c1.inspect().find(ViewType.Button.self).accessibilityLabel().string(), "Your month.")
        let failing = ActivityCalendarStore(userId: "test-\(UUID().uuidString)") { _, _ in throw URLError(.notConnectedToInternet) }
        let c2 = ActivityCalendarHomeCard(store: failing, timeZoneId: "UTC") {}
        XCTAssertEqual(try c2.inspect().find(ViewType.Button.self).accessibilityLabel().string(), "Your month.")
    }

    // MARK: Month screen (ViewInspector)

    func test_monthScreen_currentMonth_nextDisabled_previousEnabled_noTodayPill_header() async throws {
        let t = today()
        let s = await store([fullMonth(t.y, t.m)])
        let root = try ActivityCalendarMonthView(store: s, timeZoneId: "UTC").inspect()
        func button(_ label: String) throws -> InspectableView<ViewType.Button> {
            try root.find(ViewType.Button.self, where: { try $0.accessibilityLabel().string() == label })
        }
        XCTAssertTrue(try button("Next month").isDisabled(), "cannot browse into the future")
        XCTAssertFalse(try button("Previous month").isDisabled())
        XCTAssertThrowsError(try button("Jump to today"), "no Today pill on the current month")
        XCTAssertNoThrow(try root.find(text: ActivityCalendarMath.monthName(year: t.y, month: t.m, includeYear: false)))
        let n = s.activeDays(year: t.y, month: t.m)!
        XCTAssertNoThrow(try root.find(text: activeDaysText(max(n, 1))))
    }

    // MARK: Home view model gating (store only for the real service)

    func test_dashboardViewModel_storeOnlyForRealService_reusedPerUser_rebuiltOnUserChange() {
        let vm = DashboardViewModel()
        XCTAssertNil(vm.activityCalendarStore(service: ThrowingTestDataService(), userId: "u1"))
        XCTAssertNil(vm.activityCalendarStore(service: NetworkService.shared, userId: nil))
        let a = vm.activityCalendarStore(service: NetworkService.shared, userId: "u1")
        XCTAssertNotNil(a)
        XCTAssertTrue(a === vm.activityCalendarStore(service: NetworkService.shared, userId: "u1"))
        XCTAssertFalse(a === vm.activityCalendarStore(service: NetworkService.shared, userId: "u2"), "user switch must not reuse the old user's store")
    }

    // MARK: Check-in code outside Home is intact

    func test_checkInCodeStillExists_andHomeNoLongerRendersIt() throws {
        _ = CheckInRow.self
        _ = NudgeUIState.idle
        _ = ChatNudgeButton.self
        let dash = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FellowScript/Dashboard/DashboardView.swift")
        guard let src = try? String(contentsOf: dash) else { throw XCTSkip("source not readable from test sandbox") }
        let code = src.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        XCTAssertFalse(code.contains("CheckInRow("), "Home must not render the check-in row any more")
        XCTAssertTrue(code.contains("ActivityCalendarHomeCard("))
    }

    // MARK: Screenshots (dark, 375 and 420 pt, with data incl. 30/31 with three icons)

    func test_screenshots_homeCardAndTileGallery_dark_375_420() async throws {
        guard FileManager.default.fileExists(atPath: Self.screensDir) else { throw XCTSkip("screens dir missing") }
        let t = today()
        let s = await store([fullMonth(t.y, t.m)])
        for width: CGFloat in [375, 420] {
            let (w, vc) = host(ZStack(alignment: .top) {
                Theme.bgPage.ignoresSafeArea()
                VStack { Spacer().frame(height: 80); ActivityCalendarHomeCard(store: s, timeZoneId: "UTC") {}; Spacer() }
            }, width: width, height: 360)
            await settle()
            try render(vc, to: "home-card-\(Int(width))-dark")
            withExtendedLifetime(w) {}

            // Tile gallery: 30 and 31 with all three icons, plus today/future/empty/one-icon
            let (w2, vc2) = host(
                ZStack { Theme.bgPage.ignoresSafeArea()
                    VStack(spacing: 8) {
                        Spacer().frame(height: 60)
                        HStack(spacing: 6) {
                            ActivityDayTile(day: 30, kinds: [.chat, .note, .bible], style: .past, futureNumberColor: Theme.textCalendar)
                            ActivityDayTile(day: 31, kinds: [.chat, .note, .bible], style: .today, futureNumberColor: Theme.textCalendar)
                            ActivityDayTile(day: 29, kinds: [], style: .past, futureNumberColor: Theme.textCalendar)
                            ActivityDayTile(day: 28, kinds: [.note], style: .past, futureNumberColor: Theme.textCalendar)
                            ActivityDayTile(day: 27, kinds: [], style: .future, futureNumberColor: Theme.textSecondary)
                            ActivityDayTile(day: 26, kinds: [.bible, .chat], style: .past, futureNumberColor: Theme.textCalendar)
                            ActivityDayTile(day: 25, kinds: [.chat], style: .past, futureNumberColor: Theme.textCalendar)
                        }.padding(.horizontal, Theme.spacingMD)
                        Spacer()
                    }
                }, width: width, height: 240)
            await settle()
            try render(vc2, to: "tile-gallery-30-31-three-icons-\(Int(width))-dark")
            withExtendedLifetime(w2) {}
        }
    }

    func test_screenshots_monthScreen_dark_375_420() async throws {
        guard FileManager.default.fileExists(atPath: Self.screensDir) else { throw XCTSkip("screens dir missing") }
        let t = today()
        let (py, pm) = ActivityCalendarMath.shift(year: t.y, month: t.m, by: -1)
        let s = await store([fullMonth(t.y, t.m), fullMonth(py, pm)])
        for width: CGFloat in [375, 420] {
            let (w, vc) = host(ActivityCalendarMonthView(store: s, timeZoneId: "UTC"), width: width, height: 812)
            await settle()
            try render(vc, to: "month-current-\(Int(width))-dark")
            withExtendedLifetime(w) {}
        }
    }
}
