// WorkspaceLayout.swift — layout constants, feature flag and pure mode/ratio
// logic for the iPad regular-width workspace (task 20261013-ipad-adaptive-desktop-mirror).
// SOURCE: frontend/src/styles/reader-dock.css (--dock-rail-w, tab radius), Reader.jsx dock layout.
// Every tunable lives here; views carry no layout literals. Pure functions so
// the mode selection and ratio clamping are unit-testable.

import SwiftUI
import Combine

enum WorkspaceLayout {
    // Rail
    static let railWidth: CGFloat = 72
    static let railIconSize: CGFloat = 22
    static let railActiveCircle: CGFloat = 44
    static let railItemSpacing: CGFloat = 20
    // Chrome
    static let headerHeight: CGFloat = 64
    static let panelGap: CGFloat = 8
    static let outerInset: CGFloat = 8
    static let tabStripHeight: CGFloat = 44
    static let dividerHitArea: CGFloat = 24
    // Right panel (fraction of total width, clamped to points range)
    static let rightPanelDefaultRatio: Double = 0.34
    static let rightPanelMinWidth: CGFloat = 340
    static let rightPanelMaxWidth: CGFloat = 520
    // Bible / Agent Chat split (fraction of center column given to Bible)
    static let bibleSplitDefault: Double = 0.68
    static let bibleSplitMin: Double = 0.35
    static let bibleSplitMax: Double = 0.85
    // Portrait drawer
    static let drawerWidthFraction: CGFloat = 0.60
    static let drawerMaxWidth: CGFloat = 420
    // Reading column
    static let bibleColumnMaxWidth: CGFloat = 640
    static let chapterHeadingSize: CGFloat = 44
    // Popovers / modals / thread chrome
    static let popoverWidth: CGFloat = 300
    static let pinnedPopoverHeight: CGFloat = 360
    static let scheduleModalWidth: CGFloat = 520
    static let threadAvatarSize: CGFloat = 28
    static let attachGroupRadius: CGFloat = 18
    static let compactRowAvatar: CGFloat = 32
    // Motion
    static let springResponse: Double = 0.28
    static let springDamping: Double = 0.85
    // Docks (drag-tabs-between-docks + glass; design-addendum.md)
    static let collapsedDockStrip: CGFloat = 56
    static let dropEdgeBand: CGFloat = 24
    static let dropZoneInset: CGFloat = 4
    static let dockRadius: CGFloat = Theme.radiusLG
    static let railRadius: CGFloat = Theme.radiusXL
    static let dragLiftDuration: Double = 0.35
    static let dragGhostScale: CGFloat = 1.04
    static let dragSourceOpacity: Double = 0.35
    static let insertionBarWidth: CGFloat = 3
    static let tabPillHeight: CGFloat = 32
    static let tabHitHeight: CGFloat = 44
    static let noticeSeconds: Double = 2.2
    static let moveHintKey = "workspace.moveHintDismissed"
    // Glass tokens (existing hex values only: panelGlassTint is #180E06)
    static let dockTint = Color(hex: "#180E06").opacity(0.20)
    static let dockSolid = Color(hex: "#211409")          // Reduce Transparency / drawer: bgPage lifted ~6%
    static let activeDockBorder = Theme.gold.opacity(0.35)
    static let dockTopHighlight = Color.white.opacity(0.06)
    static let dockShadow = Color.black.opacity(0.35)
    static let drawerShadow = Color.black.opacity(0.45)
    static let drawerScrim = Color.black.opacity(0.45)
    static let ghostFill = Theme.gold.opacity(0.30)
    static let dropZoneFill = Theme.gold.opacity(0.08)
    static let dropZoneActiveFill = Theme.gold.opacity(0.18)
    static let dropZoneBorder = Theme.gold.opacity(0.5)
    // Feature flag (single config location). Overridable at runtime through
    // UserDefaults key `ipadWorkspaceEnabled`; when false, iPad regular width
    // shows the phone UI.
    static let featureFlagKey = "ipadWorkspaceEnabled"
    static let featureFlagDefault = true

    static func isFeatureEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: featureFlagKey) == nil ? featureFlagDefault : defaults.bool(forKey: featureFlagKey)
    }

    /// Right-panel width in points for a total width and stored ratio.
    static func rightPanelWidth(total: CGFloat, ratio: Double) -> CGFloat {
        min(rightPanelMaxWidth, max(rightPanelMinWidth, total * CGFloat(ratio)))
    }

    /// Portrait drawer width.
    static func drawerWidth(total: CGFloat) -> CGFloat {
        min(drawerMaxWidth, total * drawerWidthFraction)
    }

    static func clampBibleSplit(_ v: Double) -> Double { min(bibleSplitMax, max(bibleSplitMin, v)) }

    /// Roman numeral for the Bible "Chapter I" heading (1...3999; else decimal).
    static func roman(_ n: Int) -> String {
        guard n > 0, n < 4000 else { return String(n) }
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var rest = n, out = ""
        for (v, sym) in table { while rest >= v { out += sym; rest -= v } }
        return out
    }

    /// Landscape (docked right panel) when the canvas is wider than tall.
    static func isLandscape(_ size: CGSize) -> Bool { size.width > size.height }
}

/// Which top-level shell to show.
enum WorkspaceLayoutMode: Equatable {
    case phoneTabs
    case workspace

    /// Regular width + flag on = desktop-style workspace. Compact width (iPhone,
    /// Split View, Slide Over) or nil always keeps the existing phone UI.
    static func resolve(sizeClass: UserInterfaceSizeClass?, flagEnabled: Bool) -> WorkspaceLayoutMode {
        (sizeClass == .regular && flagEnabled) ? .workspace : .phoneTabs
    }
}

/// Left rail destinations (desktop dock rail order). The same five values are
/// the movable dock tabs (`WorkspaceTab`).
enum WorkspaceRailItem: String, CaseIterable, Identifiable, Codable {
    case bible, notes, highlights, messages, agentChat
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bible: "Bible"
        case .notes: "Notes"
        case .highlights: "Highlights"
        case .messages: "Messages"
        case .agentChat: "Agent Chat"
        }
    }
    var title: String { label.uppercased() }
    var systemIcon: String {
        switch self {
        case .bible: "book"
        case .notes: "doc.text"
        case .highlights: "highlighter"
        case .messages: "bubble.left.and.bubble.right"
        case .agentChat: "sparkles"
        }
    }
    /// The right-panel tab this item selects, nil for center-column items.
    var rightTab: WorkspaceRightTab? {
        switch self {
        case .notes: .notes
        case .highlights: .highlights
        case .messages: .messages
        default: nil
        }
    }
    /// Dock a tab lives in on a fresh layout.
    var defaultDock: WorkspaceDock {
        switch self {
        case .bible: .centerTop
        case .agentChat: .centerBottom
        case .notes, .highlights, .messages: .right
        }
    }
}

typealias WorkspaceTab = WorkspaceRailItem

enum WorkspaceRightTab: String, CaseIterable, Identifiable {
    case notes, highlights, messages
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var railItem: WorkspaceRailItem {
        switch self {
        case .notes: .notes
        case .highlights: .highlights
        case .messages: .messages
        }
    }
}

/// The three fixed tab-group docks. The rail is a launcher, not a dock.
enum WorkspaceDock: String, CaseIterable, Identifiable, Codable {
    case centerTop, centerBottom, right
    var id: String { rawValue }
    /// Final user-facing copy (menu, VoiceOver, "Move here" label).
    var displayName: String {
        switch self {
        case .centerTop: "Bible area"
        case .centerBottom: "Chat area"
        case .right: "Side panel"
        }
    }
}

/// Pure value model: which tab lives in which dock, in what order, which is
/// active per dock, which are closed and where a closed tab was last. No view
/// logic so every rule is unit-testable.
struct WorkspaceDockLayout: Codable, Equatable {
    static let schemaVersion = 1

    private(set) var version: Int = WorkspaceDockLayout.schemaVersion
    private(set) var order: [String: [WorkspaceTab]]          // keyed by dock.rawValue
    private(set) var activeByDock: [String: WorkspaceTab]     // keyed by dock.rawValue
    private(set) var lastDock: [String: WorkspaceDock]        // keyed by tab.rawValue
    private(set) var closed: [WorkspaceTab]

    static var `default`: WorkspaceDockLayout {
        var order: [String: [WorkspaceTab]] = [:]
        var active: [String: WorkspaceTab] = [:]
        for dock in WorkspaceDock.allCases {
            let tabs = WorkspaceTab.allCases.filter { $0.defaultDock == dock }
            order[dock.rawValue] = tabs
            if let first = tabs.first { active[dock.rawValue] = first }
        }
        var last: [String: WorkspaceDock] = [:]
        for t in WorkspaceTab.allCases { last[t.rawValue] = t.defaultDock }
        return WorkspaceDockLayout(order: order, activeByDock: active, lastDock: last, closed: [])
    }

    // MARK: Queries
    func tabs(in dock: WorkspaceDock) -> [WorkspaceTab] { order[dock.rawValue] ?? [] }
    func activeTab(in dock: WorkspaceDock) -> WorkspaceTab? {
        guard let t = activeByDock[dock.rawValue], tabs(in: dock).contains(t) else { return tabs(in: dock).first }
        return t
    }
    func dock(of tab: WorkspaceTab) -> WorkspaceDock? {
        WorkspaceDock.allCases.first { tabs(in: $0).contains(tab) }
    }
    func isOpen(_ tab: WorkspaceTab) -> Bool { dock(of: tab) != nil }
    var openCount: Int { WorkspaceDock.allCases.reduce(0) { $0 + tabs(in: $1).count } }
    /// Where a closed (or open) tab would reopen / currently lives.
    func homeDock(of tab: WorkspaceTab) -> WorkspaceDock { dock(of: tab) ?? lastDock[tab.rawValue] ?? tab.defaultDock }

    /// Every tab exactly once (open or closed), active tabs belong to their dock, at least one open.
    var isValid: Bool {
        let open = WorkspaceDock.allCases.flatMap { tabs(in: $0) }
        let all = open + closed
        guard Set(all).count == all.count, Set(all) == Set(WorkspaceTab.allCases), !open.isEmpty else { return false }
        for (k, t) in activeByDock {
            guard let d = WorkspaceDock(rawValue: k), tabs(in: d).contains(t) else { return false }
        }
        return true
    }

    // MARK: Mutations
    /// Make a tab the active one in its dock; a closed tab reopens in its last dock.
    mutating func activate(_ tab: WorkspaceTab) {
        if !isOpen(tab) { reopen(tab) }
        if let d = dock(of: tab) { activeByDock[d.rawValue] = tab }
    }

    mutating func reopen(_ tab: WorkspaceTab) {
        guard !isOpen(tab) else { return }
        let d = lastDock[tab.rawValue] ?? tab.defaultDock
        closed.removeAll { $0 == tab }
        order[d.rawValue, default: []].append(tab)
        activeByDock[d.rawValue] = tab
        lastDock[tab.rawValue] = d
    }

    /// Move (or reorder) a tab. `index` is in the target dock's current order
    /// (before removal); nil appends. The moved tab becomes active in the
    /// target dock. Returns false when nothing changed.
    @discardableResult
    mutating func move(_ tab: WorkspaceTab, to dock: WorkspaceDock, at index: Int? = nil) -> Bool {
        let before = self
        if let from = self.dock(of: tab) {
            var list = tabs(in: from)
            let cur = list.firstIndex(of: tab)!
            if from == dock {
                list.remove(at: cur)
                var target = index ?? list.count
                if let index, index > cur { target = index - 1 }
                list.insert(tab, at: min(max(target, 0), list.count))
                order[dock.rawValue] = list
                activeByDock[dock.rawValue] = tab
                lastDock[tab.rawValue] = dock
                return self != before
            }
            list.remove(at: cur)
            order[from.rawValue] = list
            repairActive(in: from, removedAt: cur, removed: tab)
        } else {
            closed.removeAll { $0 == tab }
        }
        var list = tabs(in: dock)
        list.insert(tab, at: min(max(index ?? list.count, 0), list.count))
        order[dock.rawValue] = list
        activeByDock[dock.rawValue] = tab
        lastDock[tab.rawValue] = dock
        return self != before
    }

    /// Close (hide) a tab, remembering its dock. Refused for the last open tab.
    @discardableResult
    mutating func close(_ tab: WorkspaceTab) -> Bool {
        guard let from = dock(of: tab), openCount > 1 else { return false }
        var list = tabs(in: from)
        let cur = list.firstIndex(of: tab)!
        list.remove(at: cur)
        order[from.rawValue] = list
        repairActive(in: from, removedAt: cur, removed: tab)
        lastDock[tab.rawValue] = from
        closed.append(tab)
        return true
    }

    /// Strip order: -1 earlier, +1 later. False at the ends.
    @discardableResult
    mutating func nudge(_ tab: WorkspaceTab, by delta: Int) -> Bool {
        guard let d = dock(of: tab), let i = tabs(in: d).firstIndex(of: tab) else { return false }
        let j = i + delta
        guard j >= 0, j < tabs(in: d).count else { return false }
        // `move` takes a pre-removal index: moving later needs j + 1.
        return move(tab, to: d, at: delta > 0 ? j + 1 : j)
    }

    private mutating func repairActive(in dock: WorkspaceDock, removedAt i: Int, removed: WorkspaceTab) {
        guard activeByDock[dock.rawValue] == removed || activeByDock[dock.rawValue] == nil else { return }
        let list = tabs(in: dock)
        if list.isEmpty { activeByDock[dock.rawValue] = nil }
        else { activeByDock[dock.rawValue] = list[min(i, list.count - 1)] }
    }

    // MARK: Persistence helpers
    /// Repairs recoverable damage (missing tabs become closed, stale actives
    /// are fixed); returns nil when the data is not usable (duplicates, wrong
    /// version, nothing open) so the caller falls back to the default layout.
    func repaired() -> WorkspaceDockLayout? {
        guard version == Self.schemaVersion else { return nil }
        var l = self
        let open = WorkspaceDock.allCases.flatMap { l.tabs(in: $0) }
        guard Set(open).count == open.count, !open.isEmpty else { return nil }
        l.closed = l.closed.filter { !open.contains($0) }
        var seen = Set<WorkspaceTab>()
        l.closed = l.closed.filter { seen.insert($0).inserted }
        for t in WorkspaceTab.allCases where !open.contains(t) && !l.closed.contains(t) { l.closed.append(t) }
        for d in WorkspaceDock.allCases {
            if let a = l.activeByDock[d.rawValue], !l.tabs(in: d).contains(a) { l.activeByDock[d.rawValue] = nil }
            if l.activeByDock[d.rawValue] == nil, let f = l.tabs(in: d).first { l.activeByDock[d.rawValue] = f }
        }
        return l.isValid ? l : nil
    }

    static func decode(_ data: Data) -> WorkspaceDockLayout? {
        (try? JSONDecoder().decode(WorkspaceDockLayout.self, from: data))?.repaired()
    }
    func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

/// Per-user, versioned, local-only persistence key.
enum WorkspaceLayoutStore {
    static func key(userId: String?) -> String {
        "workspace.dockLayout.v\(WorkspaceDockLayout.schemaVersion).\(userId ?? "_anonymous")"
    }
    static func load(defaults: UserDefaults, userId: String?) -> WorkspaceDockLayout {
        guard let data = defaults.data(forKey: key(userId: userId)),
              let l = WorkspaceDockLayout.decode(data) else { return .default }
        return l
    }
    static func save(_ layout: WorkspaceDockLayout, defaults: UserDefaults, userId: String?) {
        defaults.set(layout.encoded(), forKey: key(userId: userId))
    }
}

/// Pure hit-testing for drops (testable): which dock a point targets and
/// where in a tab strip it would insert.
enum WorkspaceDropGeometry {
    /// Generous targets: each dock grows by `dropEdgeBand` on every side and to
    /// at least `collapsedDockStrip` on its short axis; gaps route to the nearest.
    static func targetDock(at p: CGPoint, frames: [WorkspaceDock: CGRect]) -> WorkspaceDock? {
        var hits: [(WorkspaceDock, CGRect)] = []
        for (dock, raw) in frames where raw.width > 0 && raw.height > 0 {
            var r = raw.insetBy(dx: -WorkspaceLayout.dropEdgeBand, dy: -WorkspaceLayout.dropEdgeBand)
            if r.width < WorkspaceLayout.collapsedDockStrip { r = r.insetBy(dx: -(WorkspaceLayout.collapsedDockStrip - r.width) / 2, dy: 0) }
            if r.height < WorkspaceLayout.collapsedDockStrip { r = r.insetBy(dx: 0, dy: -(WorkspaceLayout.collapsedDockStrip - r.height) / 2) }
            if r.contains(p) { hits.append((dock, raw)) }
        }
        if hits.isEmpty { return nil }
        if let exact = hits.first(where: { $0.1.contains(p) }) { return exact.0 }
        return hits.min { distance(p, $0.1) < distance(p, $1.1) }?.0
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Nearest pill midpoint: the count of pills whose midpoint is left of x.
    static func insertionIndex(at x: CGFloat, pillFrames: [CGRect]) -> Int {
        pillFrames.filter { $0.midX < x }.count
    }

    /// True when the point is in the dock's tab strip band.
    static func isInStrip(_ p: CGPoint, dockFrame: CGRect) -> Bool {
        p.y <= dockFrame.minY + WorkspaceLayout.tabStripHeight + WorkspaceLayout.dropEdgeBand
    }
}

/// Persisted (local-only) workspace state. Lives in ContentView so it survives
/// size-class and rotation flips. The dock layout is stored per user.
@MainActor
final class WorkspaceState: ObservableObject {
    private let defaults: UserDefaults
    private(set) var userId: String?
    private enum Key {
        static let rightCollapsed = "workspace.rightCollapsed"
        static let rightRatio = "workspace.rightRatio"
        static let bibleSplit = "workspace.bibleSplit"
    }

    @Published private(set) var layout: WorkspaceDockLayout {
        didSet { if layout != oldValue { WorkspaceLayoutStore.save(layout, defaults: defaults, userId: userId) } }
    }
    @Published var activeRail: WorkspaceRailItem
    @Published var rightCollapsed: Bool { didSet { defaults.set(rightCollapsed, forKey: Key.rightCollapsed) } }
    @Published var rightRatio: Double { didSet { defaults.set(rightRatio, forKey: Key.rightRatio) } }
    @Published var bibleSplit: Double { didSet { defaults.set(bibleSplit, forKey: Key.bibleSplit) } }
    /// Portrait drawer visibility (transient, not persisted).
    @Published var drawerOpen = false
    /// Incremented on every successful move (haptic trigger, hint dismissal).
    @Published private(set) var moveCount = 0
    /// Brief refusal / status text shown as a toast (transient).
    @Published var notice: String?

    init(defaults: UserDefaults = .standard, userId: String? = nil) {
        self.defaults = defaults
        self.userId = userId
        let loaded = WorkspaceLayoutStore.load(defaults: defaults, userId: userId)
        layout = loaded
        activeRail = loaded.activeTab(in: .centerTop) ?? loaded.openTabsFirst ?? .bible
        rightCollapsed = defaults.bool(forKey: Key.rightCollapsed)
        rightRatio = defaults.object(forKey: Key.rightRatio) as? Double ?? WorkspaceLayout.rightPanelDefaultRatio
        let split = defaults.object(forKey: Key.bibleSplit) as? Double ?? WorkspaceLayout.bibleSplitDefault
        bibleSplit = WorkspaceLayout.clampBibleSplit(split)
    }

    /// Swap to another user's saved layout (login / account switch). Never
    /// carries the previous user's arrangement over.
    func setUser(_ id: String?) {
        guard id != userId else { return }
        userId = id
        layout = WorkspaceLayoutStore.load(defaults: defaults, userId: id)
        activeRail = layout.openTabsFirst ?? .bible
        drawerOpen = false
    }

    // MARK: Compatibility accessors (right-panel era API)
    var rightTab: WorkspaceRightTab {
        get {
            if let a = layout.activeTab(in: .right), let r = a.rightTab { return r }
            return layout.tabs(in: .right).compactMap(\.rightTab).first ?? .notes
        }
        set { layout.activate(newValue.railItem) }
    }
    var bibleCollapsed: Bool {
        get { !layout.isOpen(.bible) }
        set { if newValue { _ = layout.close(.bible) } else { layout.reopen(.bible) } }
    }
    var agentCollapsed: Bool {
        get { !layout.isOpen(.agentChat) }
        set { if newValue { _ = layout.close(.agentChat) } else { layout.reopen(.agentChat) } }
    }

    // MARK: Intents
    /// Rail tap: activate the tab in whichever dock holds it, reopening a
    /// closed tab in its last dock. A side-panel tab also opens the drawer.
    func select(_ item: WorkspaceRailItem) {
        layout.activate(item)
        activeRail = item
        if layout.dock(of: item) == .right {
            rightCollapsed = false
            drawerOpen = true
        }
    }

    /// Tab pill tap.
    func selectTab(_ tab: WorkspaceRightTab) { activateTab(tab.railItem) }
    func activateTab(_ tab: WorkspaceTab) {
        layout.activate(tab)
        activeRail = tab
        if layout.dock(of: tab) == .right { rightCollapsed = false }
    }

    /// Move / reorder a tab. Returns true when the layout changed.
    @discardableResult
    func move(_ tab: WorkspaceTab, to dock: WorkspaceDock, at index: Int? = nil, opensDrawer: Bool = false) -> Bool {
        let changed = layout.move(tab, to: dock, at: index)
        activeRail = tab
        if dock == .right { rightCollapsed = false; if opensDrawer { drawerOpen = true } }
        if changed { moveCount += 1 }
        return changed
    }

    @discardableResult
    func nudge(_ tab: WorkspaceTab, by delta: Int) -> Bool {
        let changed = layout.nudge(tab, by: delta)
        if changed { activeRail = tab; moveCount += 1 }
        return changed
    }

    /// Close a tab; refused (with a notice) for the last open tab.
    @discardableResult
    func close(_ tab: WorkspaceTab) -> Bool {
        if layout.close(tab) {
            if activeRail == tab { activeRail = layout.openTabsFirst ?? .bible }
            if layout.tabs(in: .right).isEmpty { drawerOpen = false }
            return true
        }
        notice = "At least one tab stays open."
        return false
    }

    func collapseRight() { rightCollapsed = true; drawerOpen = false }

    func resetLayout() {
        layout = .default
        activeRail = layout.activeTab(in: .centerTop) ?? .bible
        rightCollapsed = false
        rightRatio = WorkspaceLayout.rightPanelDefaultRatio
        bibleSplit = WorkspaceLayout.bibleSplitDefault
    }
}

extension WorkspaceDockLayout {
    /// First open tab in dock order (fallback focus target).
    var openTabsFirst: WorkspaceTab? {
        WorkspaceDock.allCases.compactMap { activeTab(in: $0) }.first
    }
}

/// iPad workspace: present a sheet as a centered form-sized modal (Schedule,
/// screenshot 6). No-op on the phone path.
struct WorkspaceFormSizing: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.presentationSizing(.form)
        } else {
            content
        }
    }
}
