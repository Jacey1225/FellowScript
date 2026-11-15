// ActivityCalendarViews.swift -- task 20261114-activity-calendar, steps 6 and 7.
// The Home "Your month" card and the pushed month screen, built from the
// SQUIDWARD spec (design-spec.md). iOS, dark only, owner-only data: the store
// only ever holds the signed-in user's own month labels. No streaks, no counts.
//
// Data comes from ActivityCalendarStore (step 5), whose month shape is
// {year, month, timezone, days: ["YYYY-MM-DD": [kind]]}.

import SwiftUI

// ── Date math (pure, no server involvement) ──────────────────────────────────

struct CalDay: Hashable, Comparable {
    let y: Int, m: Int, d: Int
    static func < (a: CalDay, b: CalDay) -> Bool { (a.y, a.m, a.d) < (b.y, b.m, b.d) }
    var key: String { String(format: "%04d-%02d-%02d", y, m, d) }
}

enum ActivityCalendarMath {
    /// Pure date arithmetic on Gregorian components (UTC so no DST edge), with
    /// the device's week start.
    static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = Calendar.current.firstWeekday
        c.locale = Calendar.current.locale
        return c
    }

    /// Today in the user's stored timezone (falls back to the device zone).
    static func today(timeZoneId: String?, now: Date = Date()) -> CalDay {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZoneId.flatMap(TimeZone.init(identifier:)) ?? .current
        let p = c.dateComponents([.year, .month, .day], from: now)
        return CalDay(y: p.year!, m: p.month!, d: p.day!)
    }

    static func date(_ d: CalDay) -> Date {
        cal.date(from: DateComponents(year: d.y, month: d.m, day: d.d))!
    }

    static func day(_ date: Date) -> CalDay {
        let p = cal.dateComponents([.year, .month, .day], from: date)
        return CalDay(y: p.year!, m: p.month!, d: p.day!)
    }

    static func daysIn(year: Int, month: Int) -> Int {
        cal.range(of: .day, in: .month, for: date(CalDay(y: year, m: month, d: 1)))!.count
    }

    /// Blank cells before day 1 so the weekday columns line up.
    static func leadingBlanks(year: Int, month: Int) -> Int {
        let wd = cal.component(.weekday, from: date(CalDay(y: year, m: month, d: 1)))
        return (wd - cal.firstWeekday + 7) % 7
    }

    /// Very-short weekday symbols starting at the locale's first weekday.
    static func weekdayInitials() -> [String] {
        let s = Calendar.current.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return (0..<7).map { s[(first + $0) % 7] }
    }

    /// The 7 days of the week containing `day`.
    static func week(containing day: CalDay) -> [CalDay] {
        let wd = cal.component(.weekday, from: date(day))
        let offset = (wd - cal.firstWeekday + 7) % 7
        let start = cal.date(byAdding: .day, value: -offset, to: date(day))!
        return (0..<7).map { self.day(cal.date(byAdding: .day, value: $0, to: start)!) }
    }

    static func shift(year: Int, month: Int, by delta: Int) -> (Int, Int) {
        let idx = year * 12 + (month - 1) + delta
        return (idx / 12, idx % 12 + 1)
    }

    /// How far back the month screen lets the user browse. The server contract
    /// carries no account-start date, so this is a fixed window.
    static let browseBackMonths = 36

    /// First day Bible reading was recorded, for the "counted from" note. The
    /// server contract has no `kind_recorded_from` yet, so this stays nil (the
    /// note is wired but hidden) until a ship date or field is available.
    static let bibleRecordedFrom: CalDay? = nil

    static func monthName(year: Int, month: Int, includeYear: Bool) -> String {
        let f = DateFormatter()
        f.locale = Calendar.current.locale ?? .current
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate(includeYear ? "LLLL yyyy" : "LLLL")
        return f.string(from: date(CalDay(y: year, m: month, d: 1)))
    }

    static func dayLabel(_ day: CalDay, kinds: [FSActivityKind], isToday: Bool) -> String {
        let f = DateFormatter()
        f.locale = Calendar.current.locale ?? .current
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        let date = f.string(from: self.date(day))
        let names: [String] = kinds.map {
            switch $0 {
            case .bible: return "Bible reading"
            case .note:  return "note"
            case .chat:  return "chat"
            }
        }
        var what = names.isEmpty ? "No activity"
                                 : (ListFormatter.localizedString(byJoining: names))
        what = what.prefix(1).uppercased() + what.dropFirst()
        return (isToday ? "Today, " : "") + "\(date). \(what)."
    }
}

// ── Tile ─────────────────────────────────────────────────────────────────────

private struct CalendarChevron: Shape {
    var pointsRight = true
    func path(in r: CGRect) -> Path {
        var p = Path()
        let a = pointsRight ? r.minX : r.maxX, b = pointsRight ? r.maxX : r.minX
        p.move(to: CGPoint(x: a, y: r.minY))
        p.addLine(to: CGPoint(x: b, y: r.midY))
        p.addLine(to: CGPoint(x: a, y: r.maxY))
        return p
    }
}

/// One day. Square, radius 12, four quadrants: number top-left, Bible top-right,
/// note bottom-left, chat bottom-right. Icons never move.
struct ActivityDayTile: View {
    enum Style { case past, today, future }
    let day: Int
    let kinds: [FSActivityKind]
    let style: Style
    /// Future numbers: 55% on the month screen, 70% on the Home card.
    let futureNumberColor: Color

    private func icon(_ kind: FSActivityKind, _ name: String, glyph: CGFloat) -> some View {
        Image(name)
            .renderingMode(.template)
            .resizable().scaledToFit()
            .frame(width: glyph, height: glyph)
            .foregroundStyle(Theme.parchment)
            .opacity(kinds.contains(kind) ? 1 : 0)
            .accessibilityHidden(true)
    }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(GeometryReader { g in tile(size: g.size.width) })
    }

    private func tile(size: CGFloat) -> some View {
        let q = (size - 8) / 2
        let glyph: CGFloat = q >= 18.5 ? 13 : 12
        let active = !kinds.isEmpty
        let shape = RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
        let numberColor: Color = style == .today ? Theme.goldLight
                               : style == .future ? futureNumberColor : Theme.textCalendar

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("\(day)")
                    .font(.inter(Theme.fontXS, weight: .semibold))
                    .foregroundColor(numberColor)
                    .lineLimit(1).fixedSize()
                    .frame(width: q, height: q)
                icon(.bible, "ActivityBible", glyph: glyph).frame(width: q, height: q)
            }
            HStack(spacing: 0) {
                icon(.note, "ActivityNote", glyph: glyph).frame(width: q, height: q)
                icon(.chat, "ActivityChat", glyph: glyph).frame(width: q, height: q)
            }
        }
        .padding(4)
        .frame(width: size, height: size)
        .background(
            Group {
                switch style {
                case .future: Color.clear
                default:
                    active ? Theme.gold.opacity(0.16) : Theme.parchment.opacity(0.065)
                }
            }
            .clipShape(shape)
        )
        .overlay {
            if style == .today {
                shape.strokeBorder(Theme.goldLight, lineWidth: 1.5)
            } else if style == .future {
                shape.strokeBorder(Theme.parchment.opacity(0.10), lineWidth: 1)
            }
        }
        .contentShape(shape)
    }
}

// ── Home card ────────────────────────────────────────────────────────────────

private struct CalendarCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Pill used by both the Home card and the month screen's Today pill
/// (the CheckInRow pill style with different words).
private struct CalendarPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(Theme.goldLight.opacity(0.85))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .overlay(Capsule().stroke(Theme.gold.opacity(0.35), lineWidth: 1))
    }
}

func activeDaysText(_ n: Int) -> String {
    n == 1 ? "Active on 1 day this month" : "Active on \(n) days this month"
}

extension ActivityCalendarStore {
    /// Days in a month with any activity (a date count, not a per-kind count).
    func activeDays(year: Int, month: Int) -> Int? {
        self.month(year: year, month: month).map { $0.days.values.filter { !$0.isEmpty }.count }
    }

    func kinds(on day: CalDay) -> [FSActivityKind] {
        month(year: day.y, month: day.m)?.kinds(on: day.key) ?? []
    }

    /// Load cached then refresh. A failed refresh keeps the last good month
    /// (the store guarantees that); no error string is shown in calendar UI.
    func load(year: Int, month: Int) async {
        await loadCached(year: year, month: month)
        try? await refresh(year: year, month: month)
    }
}

struct ActivityCalendarHomeCard: View {
    @ObservedObject var store: ActivityCalendarStore
    let timeZoneId: String?
    let onOpen: () -> Void

    var body: some View {
        let today = ActivityCalendarMath.today(timeZoneId: timeZoneId)
        let week = ActivityCalendarMath.week(containing: today)
        let n = store.activeDays(year: today.y, month: today.m)
        let initials = ActivityCalendarMath.weekdayInitials()

        Button(action: onOpen) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your month")
                            .font(.system(size: 17, weight: .heavy))
                            .foregroundColor(Theme.parchment)
                            .frame(height: 22, alignment: .leading)
                        if let n, n > 0 {
                            CalendarPill(text: activeDaysText(n))
                        } else {
                            Color.clear.frame(height: 20)
                        }
                    }
                    Spacer(minLength: 0)
                    CalendarChevron()
                        .stroke(Theme.gold.opacity(0.75),
                                style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        .frame(width: 6, height: 12)
                        .frame(width: 14, height: 22)
                        .padding(.top, 6)
                        .accessibilityHidden(true)
                }
                .frame(height: 48)
                .padding(.horizontal, 4)

                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { i in
                        Text(initials[i])
                            .font(.inter(Theme.fontXS, weight: .semibold))
                            .tracking(0.5)
                            .foregroundColor(Theme.textCalendar)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 16)
                .padding(.top, 14)
                .accessibilityHidden(true)

                HStack(spacing: 6) {
                    ForEach(week, id: \.self) { d in
                        ActivityDayTile(day: d.d,
                                        kinds: d > today ? [] : store.kinds(on: d),
                                        style: d == today ? .today : (d > today ? .future : .past),
                                        futureNumberColor: Theme.textCalendar)
                    }
                }
                .padding(.top, 8)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .glassCard(cornerRadius: Theme.radiusXL)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusXL, style: .continuous))
        }
        .buttonStyle(CalendarCardButtonStyle())
        .padding(.horizontal, 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(n.map { $0 > 0 ? "Your month. \(activeDaysText($0))." : "Your month." } ?? "Your month.")
        .accessibilityHint("Opens the full month.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("activity-calendar-home-card")
        // Home shows the week that contains today; when that week straddles
        // a month boundary, fetch the neighbouring month too.
        .task(id: "\(today.y)-\(today.m)-\(week.first!.m)-\(week.last!.m)") {
            var seen = Set<[Int]>()
            for d in [today] + week where seen.insert([d.y, d.m]).inserted {
                await store.load(year: d.y, month: d.m)
            }
        }
    }
}

// ── Month screen ─────────────────────────────────────────────────────────────

struct ActivityCalendarMonthView: View {
    @ObservedObject var store: ActivityCalendarStore
    let timeZoneId: String?
    @Environment(\.dismiss) private var dismiss
    @State private var shown: (y: Int, m: Int)? = nil

    private var today: CalDay { ActivityCalendarMath.today(timeZoneId: timeZoneId) }
    private var current: (y: Int, m: Int) { (shown ?? (today.y, today.m)) }

    private var earliest: (Int, Int) {
        ActivityCalendarMath.shift(year: today.y, month: today.m, by: -ActivityCalendarMath.browseBackMonths)
    }
    private var canGoBack: Bool { current.y * 12 + current.m > earliest.0 * 12 + earliest.1 }
    private var canGoForward: Bool { current.y * 12 + current.m < today.y * 12 + today.m }
    private var isCurrentMonth: Bool { current.y == today.y && current.m == today.m }

    private func go(_ delta: Int) {
        let (y, m) = ActivityCalendarMath.shift(year: current.y, month: current.m, by: delta)
        shown = (y, m)
    }

    var body: some View {
        let y = current.y, m = current.m
        VStack(spacing: 0) {
            backRow
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header(y: y, m: m).padding(.top, 12)
                    weekdayRow.padding(.top, 20)
                    grid(y: y, m: m).padding(.top, 8)
                    boundsNote(y: y, m: m)
                }
                .padding(.horizontal, Theme.spacingMD)
                .padding(.bottom, 150) // clears the floating tab bar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .warmBloomBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: ActivityCalendarStore.monthKey(year: y, month: m)) {
            await store.load(year: y, month: m)
        }
    }

    private var backRow: some View {
        HStack {
            Button { dismiss() } label: {
                HStack(spacing: 6) {
                    CalendarChevron(pointsRight: false)
                        .stroke(Theme.gold, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        .frame(width: 8, height: 14)
                    Text("Home").font(.system(size: 17)).foregroundColor(Theme.gold)
                }
                .padding(.horizontal, Theme.spacingMD)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Home")
            .accessibilityAddTraits(.isButton)
            Spacer()
        }
    }

    @ViewBuilder
    private func header(y: Int, m: Int) -> some View {
        let n = store.activeDays(year: y, month: m) ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text(ActivityCalendarMath.monthName(year: y, month: m, includeYear: y != today.y))
                    .font(.interScaled(Theme.fontDisplayMD, weight: .bold, relativeTo: .title2))
                    .foregroundColor(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if !isCurrentMonth {
                    Button { shown = nil } label: {
                        CalendarPill(text: "Today")
                            .padding(.horizontal, 5)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jump to today")
                    .padding(.trailing, 1)
                }
                navButton(forward: false, enabled: canGoBack, label: "Previous month") { go(-1) }
                navButton(forward: true, enabled: canGoForward, label: "Next month") { go(1) }
            }
            .frame(minHeight: 44)
            // Hidden at 0 days, but the line keeps its space so the grid never jumps.
            Text(activeDaysText(max(n, 1)))
                .font(.interScaled(Theme.fontSM, weight: .regular, relativeTo: .subheadline))
                .foregroundColor(Theme.textCalendar)
                .opacity(n > 0 ? 1 : 0)
                .accessibilityHidden(n == 0)
                .accessibilityLabel(n > 0 ? "\(activeDaysText(n))." : "")
        }
    }

    private func navButton(forward: Bool, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CalendarChevron(pointsRight: forward)
                .stroke(enabled ? Theme.textPrimary : Theme.textMuted,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 6, height: 12)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var weekdayRow: some View {
        let initials = ActivityCalendarMath.weekdayInitials()
        return HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { i in
                Text(initials[i])
                    .font(.inter(Theme.fontXS, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(Theme.textCalendar)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }

    private func grid(y: Int, m: Int) -> some View {
        let blanks = ActivityCalendarMath.leadingBlanks(year: y, month: m)
        let count = ActivityCalendarMath.daysIn(year: y, month: m)
        let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        let t = today
        return LazyVGrid(columns: cols, spacing: 6) {
            ForEach(0..<blanks, id: \.self) { _ in
                Color.clear.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
            }
            ForEach(1...count, id: \.self) { d in
                let day = CalDay(y: y, m: m, d: d)
                let future = day > t
                let isToday = day == t
                let kinds = future ? [] : store.kinds(on: day)
                ActivityDayTile(day: d, kinds: kinds,
                                style: isToday ? .today : (future ? .future : .past),
                                futureNumberColor: Theme.textSecondary)
                    // Future days are not focus targets; v1 day tiles carry no button trait.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(ActivityCalendarMath.dayLabel(day, kinds: kinds, isToday: isToday))
                    .accessibilityHidden(future)
            }
        }
    }

    @ViewBuilder
    private func boundsNote(y: Int, m: Int) -> some View {
        if let from = ActivityCalendarMath.bibleRecordedFrom,
           CalDay(y: y, m: m, d: 1) < from {
            let f = DateFormatter()
            let _ = f.setLocalizedDateFormatFromTemplate(from.y == today.y ? "MMMMd" : "MMMMdyyyy")
            let _ = f.timeZone = TimeZone(identifier: "UTC")
            Text("Bible reading is counted from \(f.string(from: ActivityCalendarMath.date(from))).")
                .font(.interScaled(Theme.fontXS, relativeTo: .caption))
                .foregroundColor(Theme.textSecondary)
                .padding(.top, 20)
        }
    }
}
