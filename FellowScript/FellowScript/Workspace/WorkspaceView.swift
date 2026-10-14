// WorkspaceView.swift — iPad regular-width workspace mirroring the desktop Reader
// (task 20261013-ipad-adaptive-desktop-mirror).
// SOURCE: frontend/src/pages/Reader.jsx (dockview layout), reader-dock.css, AppNav.jsx
// LAYOUT: header (wordmark + avatar menu) / left rail (launcher) / three tab-group
//         docks (centerTop = Bible area, centerBottom = Chat area, right = Side
//         panel). Tabs drag between docks (long-press then drag); the Move to menu
//         and VoiceOver actions do the same without dragging. Docks are frosted
//         glass over the gold glow page; the portrait Side panel is an opaque drawer.
// All constants live in WorkspaceLayout; existing screens are re-hosted, not rewritten.
// DRAG: a sequenced LongPress+DragGesture (not .draggable) because SwiftUI's
// drag-and-drop gives no begin/cancel signal, which the drop-zone overlays,
// collapsed strips, haptics and cancel snap-back all need.

import SwiftUI
import Combine

private let workspaceSpace = "workspace"

// MARK: - Geometry reporting

private struct DockFramesKey: PreferenceKey {
    static var defaultValue: [WorkspaceDock: CGRect] = [:]
    static func reduce(value: inout [WorkspaceDock: CGRect], nextValue: () -> [WorkspaceDock: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct PillFramesKey: PreferenceKey {
    static var defaultValue: [WorkspaceTab: CGRect] = [:]
    static func reduce(value: inout [WorkspaceTab: CGRect], nextValue: () -> [WorkspaceTab: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Drag state

/// Finger position lives apart from the rest of the drag state so only the
/// floating ghost re-renders at touch rate.
@MainActor
final class DragPointer: ObservableObject {
    @Published var location: CGPoint = .zero
}

@MainActor
final class WorkspaceDragState: ObservableObject {
    @Published private(set) var tab: WorkspaceTab?
    @Published private(set) var target: WorkspaceDock?
    @Published private(set) var insertIndex: Int?
    @Published private(set) var liftCount = 0
    let pointer = DragPointer()
    // Geometry snapshots (plain vars: updating them must not re-render).
    var dockFrames: [WorkspaceDock: CGRect] = [:]
    var pillFrames: [WorkspaceTab: CGRect] = [:]

    var isActive: Bool { tab != nil }

    func begin(_ tab: WorkspaceTab) {
        guard self.tab == nil else { return }
        self.tab = tab
        liftCount += 1
    }

    func update(_ p: CGPoint, layout: WorkspaceDockLayout) {
        guard tab != nil else { return }
        pointer.location = p
        let t = WorkspaceDropGeometry.targetDock(at: p, frames: dockFrames)
        var idx: Int?
        if let t, let frame = dockFrames[t], WorkspaceDropGeometry.isInStrip(p, dockFrame: frame) {
            let frames = layout.tabs(in: t).compactMap { pillFrames[$0] }
            if !frames.isEmpty { idx = WorkspaceDropGeometry.insertionIndex(at: p.x, pillFrames: frames) }
        }
        if t != target { target = t }
        if idx != insertIndex { insertIndex = idx }
    }

    /// Ends the drag, returning what was dropped where (nil dock = cancelled).
    func finish() -> (tab: WorkspaceTab, dock: WorkspaceDock?, index: Int?)? {
        guard let tab else { return nil }
        let result = (tab: tab, dock: target, index: insertIndex)
        self.tab = nil; target = nil; insertIndex = nil
        return result
    }
}

// MARK: - Actions handed to tab pills

struct DockTabActions {
    var select: () -> Void
    var close: () -> Void
    var move: (WorkspaceDock) -> Void
    var nudge: (Int) -> Void
    var reset: () -> Void
    var lift: () -> Void
    var drag: (CGPoint) -> Void
    var drop: (CGPoint) -> Void
    var cancel: () -> Void
    var destinations: [WorkspaceDock]
    var canEarlier: Bool
    var canLater: Bool
}

// MARK: - View

struct WorkspaceView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var state: WorkspaceState
    let startup: StartupCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var drag = WorkspaceDragState()
    @AppStorage(WorkspaceLayout.moveHintKey) private var moveHintDismissed = false
    @State private var showHome = false
    @State private var showAccount = false
    @State private var agentId: String?
    @State private var showNewAgent = false
    @State private var newAgentRole = ""
    @GestureState private var splitDrag: CGFloat = 0

    private var spring: Animation { .spring(response: WorkspaceLayout.springResponse, dampingFraction: WorkspaceLayout.springDamping) }
    private func animate(_ body: () -> Void) { withMotionAwareAnimation(spring, reduceMotion: reduceMotion, body) }

    var body: some View {
        GeometryReader { geo in
            let landscape = WorkspaceLayout.isLandscape(geo.size)
            let layout = state.layout
            let centerHas = !layout.tabs(in: .centerTop).isEmpty || !layout.tabs(in: .centerBottom).isEmpty
            let drawerMode = !landscape && centerHas
            ZStack {
                background
                VStack(spacing: WorkspaceLayout.panelGap) {
                    header
                    HStack(spacing: WorkspaceLayout.panelGap) {
                        rail
                        if centerHas || drag.isActive {
                            centerColumn(landscape: landscape)
                        }
                        if !drawerMode { rightColumn(landscape: landscape, total: geo.size.width, centerVisible: centerHas || drag.isActive) }
                    }
                }
                .padding(WorkspaceLayout.outerInset)

                if drawerMode { drawerLayer(total: geo.size.width) }
                dragOverlays
                noticeToast
            }
            .coordinateSpace(name: workspaceSpace)
            .onPreferenceChange(DockFramesKey.self) { drag.dockFrames = $0 }
            .onPreferenceChange(PillFramesKey.self) { drag.pillFrames = $0 }
            .animation(reduceMotion ? nil : spring, value: state.rightCollapsed)
            .animation(reduceMotion ? nil : spring, value: state.drawerOpen)
            .animation(reduceMotion ? nil : spring, value: drag.isActive)
            .animation(reduceMotion ? nil : spring, value: state.layout)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: drag.liftCount)
        .sensoryFeedback(.selection, trigger: drag.target)
        .sensoryFeedback(.success, trigger: state.moveCount)
        .onChange(of: state.moveCount) { _, n in if n > 0 { moveHintDismissed = true } }
        .onChange(of: state.notice) { _, text in
            guard text != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(WorkspaceLayout.noticeSeconds))
                state.notice = nil
            }
        }
        .sheet(isPresented: $showHome) {
            DashboardView(vm: startup.dashboardVM).environmentObject(startup.chatVM).environmentObject(appState)
        }
        .sheet(isPresented: $showAccount) { AccountView().environmentObject(appState) }
        .sheet(isPresented: $showNewAgent) {
            NewAgentSheet(role: $newAgentRole) {
                let role = newAgentRole
                newAgentRole = ""
                let uid = appState.currentUser?.user_id ?? ""
                Task { await startup.chatVM.createAgent(role: role, userId: uid) }
            }
        }
        // Existing deep links map onto rail selection.
        .onChange(of: appState.pendingBibleNav) { _, t in if t != nil { state.select(.bible) } }
        .onChange(of: appState.pendingChatContact) { _, t in if t != nil { state.select(.messages) } }
        .onReceive(NotificationCenter.default.publisher(for: .fsOpenSubscriptionPlans)) { _ in showAccount = true }
        .onAppear { state.setUser(appState.currentUser?.user_id) }
        .onChange(of: appState.currentUser?.user_id) { _, id in state.setUser(id) }
        .preferredColorScheme(.dark)
    }

    // MARK: Chrome

    private var background: some View {
        ZStack {
            Theme.bgPage.ignoresSafeArea()
            RadialGradient(colors: [Color(hex: "#D4922A").opacity(0.20), .clear],
                           center: UnitPoint(x: 0.12, y: 0.0), startRadius: 10, endRadius: 520).ignoresSafeArea()
            RadialGradient(colors: [Color(hex: "#B8761D").opacity(0.08), .clear],
                           center: UnitPoint(x: 0.92, y: 0.60), startRadius: 10, endRadius: 420).ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack {
            Text("FellowScript")
                .font(Font.schibstedWordmark(26, relativeTo: .title))
                .foregroundColor(Theme.parchment)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Menu {
                Button("Home", systemImage: "house") { showHome = true }
                Button("Account", systemImage: "person.crop.circle") { showAccount = true }
                Button("Reset layout", systemImage: "rectangle.3.group") { animate { state.resetLayout() } }
            } label: {
                Text(appState.currentUser?.username.prefix(1).uppercased() ?? "?")
                    .font(.inter(Theme.fontSM, weight: .bold))
                    .foregroundColor(Theme.goldLight)
                    .frame(width: 32, height: 32)
                    .overlay(Circle().stroke(Theme.gold, lineWidth: 1.5))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Account menu")
        }
        .frame(height: WorkspaceLayout.headerHeight - 2 * WorkspaceLayout.outerInset)
        .padding(.horizontal, 8)
    }

    /// The rail is a launcher, not a dock: it is glass-styled but never a drop target.
    private var rail: some View {
        VStack(spacing: WorkspaceLayout.railItemSpacing) {
            ForEach(WorkspaceRailItem.allCases) { item in
                let active = state.activeRail == item
                let home = state.layout.dock(of: item)
                Button {
                    animate { state.select(item) }
                } label: {
                    Image(systemName: item.systemIcon)
                        .font(.system(size: WorkspaceLayout.railIconSize, weight: .medium))
                        .foregroundColor(active ? Color(hex: "#24170A") : Theme.tabInactive)
                        .frame(width: WorkspaceLayout.railActiveCircle, height: WorkspaceLayout.railActiveCircle)
                        .background(Circle().fill(active ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(Color.clear)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityValue(home?.displayName ?? "Closed")
                .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
            }
            Spacer()
        }
        .padding(.vertical, 16)
        .frame(width: WorkspaceLayout.railWidth)
        .modifier(WorkspaceDockStyle(radius: WorkspaceLayout.railRadius))
    }

    // MARK: Center column (Bible area over Chat area)

    private func centerColumn(landscape: Bool) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            let gap = WorkspaceLayout.panelGap
            let topHas = !state.layout.tabs(in: .centerTop).isEmpty
            let botHas = !state.layout.tabs(in: .centerBottom).isEmpty
            let both = topHas && botHas
            let avail = max(h - gap, 1)
            let ratio = WorkspaceLayout.clampBibleSplit(state.bibleSplit + Double(splitDrag / avail))
            VStack(spacing: gap) {
                if topHas {
                    dockPanel(.centerTop, landscape: landscape)
                        .frame(height: both ? avail * CGFloat(ratio) : nil)
                } else if drag.isActive {
                    emptyStrip(.centerTop, vertical: false, fill: !botHas)
                }
                if botHas {
                    dockPanel(.centerBottom, landscape: landscape).frame(maxHeight: .infinity)
                } else if drag.isActive {
                    emptyStrip(.centerBottom, vertical: false, fill: !topHas)
                }
            }
            .overlay(alignment: .top) {
                if both {
                    divider.offset(y: avail * CGFloat(ratio) - WorkspaceLayout.dividerHitArea / 2 + gap / 2)
                        .gesture(
                            DragGesture()
                                .updating($splitDrag) { v, s, _ in s = v.translation.height }
                                .onEnded { v in state.bibleSplit = WorkspaceLayout.clampBibleSplit(state.bibleSplit + Double(v.translation.height / avail)) }
                        )
                }
            }
        }
    }

    private var divider: some View {
        Capsule().fill(Theme.borderGold).frame(width: 48, height: 3)
            .frame(maxWidth: .infinity, minHeight: WorkspaceLayout.dividerHitArea)
            .contentShape(Rectangle())
            .accessibilityLabel("Resize Bible area and Chat area")
            .accessibilityAdjustableAction { dir in
                let d = dir == .increment ? 0.05 : -0.05
                state.bibleSplit = WorkspaceLayout.clampBibleSplit(state.bibleSplit + d)
            }
    }

    // MARK: Side panel

    @ViewBuilder
    private func rightColumn(landscape: Bool, total: CGFloat, centerVisible: Bool) -> some View {
        let hasTabs = !state.layout.tabs(in: .right).isEmpty
        let collapsed = state.rightCollapsed && centerVisible
        if collapsed && (hasTabs || drag.isActive) {
            emptyStrip(.right, vertical: true, fill: false, expandAction: { animate { state.rightCollapsed = false } })
        } else if hasTabs {
            dockPanel(.right, landscape: landscape)
                .frame(width: centerVisible ? WorkspaceLayout.rightPanelWidth(total: total, ratio: state.rightRatio) : nil)
                .frame(maxWidth: centerVisible ? nil : .infinity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else if drag.isActive {
            emptyStrip(.right, vertical: true, fill: false)
        }
    }

    /// Portrait: the Side panel is an opaque trailing drawer over a scrim.
    @ViewBuilder
    private func drawerLayer(total: CGFloat) -> some View {
        let hasTabs = !state.layout.tabs(in: .right).isEmpty
        if state.drawerOpen && hasTabs {
            WorkspaceLayout.drawerScrim.ignoresSafeArea()
                .onTapGesture { animate { state.drawerOpen = false } }
                .accessibilityHidden(true)
            HStack {
                Spacer()
                dockPanel(.right, landscape: false, drawer: true)
                    .frame(width: WorkspaceLayout.drawerWidth(total: total))
                    .padding(.vertical, WorkspaceLayout.outerInset)
                    .transition(.move(edge: .trailing))
            }
        } else if drag.isActive {
            // Drawer closed: a trailing strip is the drop target for the Side panel.
            HStack {
                Spacer()
                emptyStrip(.right, vertical: true, fill: false)
                    .padding(.vertical, WorkspaceLayout.outerInset)
                    .padding(.trailing, WorkspaceLayout.outerInset)
            }
        }
    }

    // MARK: Dock panel

    private func dockPanel(_ dock: WorkspaceDock, landscape: Bool, drawer: Bool = false) -> some View {
        let tabs = state.layout.tabs(in: dock)
        let active = state.layout.activeTab(in: dock)
        let isActiveDock = state.layout.dock(of: state.activeRail) == dock
        return VStack(spacing: 0) {
            tabStrip(dock, tabs: tabs, active: active, landscape: landscape, showCollapse: dock == .right && landscape && !drawer)
            if dock == .right && !moveHintDismissed {
                Text("Touch and hold a tab to move it.")
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 6)
            }
            dockBody(active)
        }
        .modifier(WorkspaceDockStyle(radius: WorkspaceLayout.dockRadius, isActive: isActiveDock, drawer: drawer))
        .overlay { dropZone(dock, label: nil) }
        .background(frameReporter(dock))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(dock.displayName)
    }

    private func frameReporter(_ dock: WorkspaceDock) -> some View {
        GeometryReader { g in
            Color.clear.preference(key: DockFramesKey.self, value: [dock: g.frame(in: .named(workspaceSpace))])
        }
    }

    /// A dock with no tabs: visible only while a drag is active (or as the
    /// user-collapsed Side panel), a 56pt glass strip that is still a target.
    private func emptyStrip(_ dock: WorkspaceDock, vertical: Bool, fill: Bool, expandAction: (() -> Void)? = nil) -> some View {
        let strip = WorkspaceLayout.collapsedDockStrip
        return ZStack {
            if let expandAction {
                Button(action: expandAction) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.goldLight)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Expand Side panel")
            } else {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 20)).foregroundColor(Theme.tabInactive)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: vertical ? strip : .infinity, maxHeight: vertical ? .infinity : (fill ? .infinity : strip))
        .frame(minHeight: vertical ? nil : strip)
        .modifier(WorkspaceDockStyle(radius: WorkspaceLayout.dockRadius))
        .overlay { dropZone(dock, label: "Drop here", vertical: vertical) }
        .background(frameReporter(dock))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(dock.displayName)
    }

    // MARK: Drop zones

    @ViewBuilder
    private func dropZone(_ dock: WorkspaceDock, label: String?, vertical: Bool = false) -> some View {
        if let dragged = drag.tab {
            let isTarget = drag.target == dock
            let isSource = state.layout.dock(of: dragged) == dock
            let shape = RoundedRectangle(cornerRadius: WorkspaceLayout.dockRadius - WorkspaceLayout.dropZoneInset, style: .continuous)
            ZStack {
                shape.fill(isTarget ? WorkspaceLayout.dropZoneActiveFill : WorkspaceLayout.dropZoneFill)
                if isTarget {
                    shape.stroke(Theme.goldLight, lineWidth: 2)
                } else {
                    shape.stroke(WorkspaceLayout.dropZoneBorder, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }
                if let text = label ?? ((isTarget && !isSource) ? "Move here" : nil) {
                    Text(text)
                        .font(.inter(Theme.fontXS, weight: .bold)).foregroundColor(Theme.ink)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Theme.goldGradient))
                        .rotationEffect(vertical ? .degrees(-90) : .zero)
                }
            }
            .padding(WorkspaceLayout.dropZoneInset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }

    /// Insertion bar in the target strip and the floating drag preview.
    @ViewBuilder
    private var dragOverlays: some View {
        if let tab = drag.tab {
            if let target = drag.target, let idx = drag.insertIndex,
               let dockFrame = drag.dockFrames[target] {
                let frames = state.layout.tabs(in: target).compactMap { drag.pillFrames[$0] }
                if !frames.isEmpty {
                    let x = idx < frames.count ? frames[idx].minX - 3 : (frames.last?.maxX ?? 0) + 3
                    Capsule().fill(Theme.goldLight)
                        .frame(width: WorkspaceLayout.insertionBarWidth, height: WorkspaceLayout.tabPillHeight)
                        .position(x: x, y: dockFrame.minY + WorkspaceLayout.tabStripHeight / 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            DragGhost(tab: tab, pointer: drag.pointer)
        }
    }

    @ViewBuilder
    private var noticeToast: some View {
        if let text = state.notice {
            VStack {
                Spacer()
                Text(text)
                    .font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.goldLight)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(WorkspaceLayout.dockSolid))
                    .overlay(Capsule().stroke(WorkspaceLayout.activeDockBorder, lineWidth: 1))
                    .padding(.bottom, 24)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    // MARK: Tab strip

    private func tabStrip(_ dock: WorkspaceDock, tabs: [WorkspaceTab], active: WorkspaceTab?, landscape: Bool, showCollapse: Bool) -> some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tabs) { tab in
                            DockTabPill(tab: tab, isActive: tab == active, isDragged: drag.tab == tab,
                                        actions: pillActions(tab, dock: dock, tabs: tabs, landscape: landscape))
                                .id(tab)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: active) { _, t in
                    if let t { withMotionAwareAnimation(spring, reduceMotion: reduceMotion) { proxy.scrollTo(t, anchor: .center) } }
                }
            }
            if showCollapse {
                Button { animate { state.collapseRight() } } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.goldLight)
                        .frame(width: 44, height: WorkspaceLayout.tabStripHeight).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse Side panel")
            }
        }
        .frame(height: WorkspaceLayout.tabStripHeight)
    }

    private func pillActions(_ tab: WorkspaceTab, dock: WorkspaceDock, tabs: [WorkspaceTab], landscape: Bool) -> DockTabActions {
        let idx = tabs.firstIndex(of: tab) ?? 0
        return DockTabActions(
            select: { animate { state.activateTab(tab) } },
            close: { animate { _ = state.close(tab) } },
            move: { d in performMove(tab, to: d, index: nil, landscape: landscape) },
            nudge: { delta in
                animate { if state.nudge(tab, by: delta) { announce("\(tab.label) moved \(delta < 0 ? "earlier" : "later")") } }
            },
            reset: { animate { state.resetLayout() }; announce("Layout reset.") },
            lift: { drag.begin(tab) },
            drag: { p in drag.update(p, layout: state.layout) },
            drop: { p in drag.update(p, layout: state.layout); finishDrag(landscape: landscape) },
            cancel: { _ = drag.finish() },
            destinations: WorkspaceDock.allCases.filter { $0 != dock },
            canEarlier: idx > 0,
            canLater: idx < tabs.count - 1
        )
    }

    private func performMove(_ tab: WorkspaceTab, to dock: WorkspaceDock, index: Int?, landscape: Bool) {
        var moved = false
        animate { moved = state.move(tab, to: dock, at: index, opensDrawer: !landscape) }
        if moved { announce("\(tab.label) moved to \(dock.displayName).") }
    }

    private func finishDrag(landscape: Bool) {
        guard let r = drag.finish() else { return }
        // No target = cancelled. Dropping on the tab's own dock body is a no-op;
        // dropping in its own strip reorders.
        guard let dock = r.dock else { return }
        if state.layout.dock(of: r.tab) == dock && r.index == nil { return }
        performMove(r.tab, to: dock, index: r.index, landscape: landscape)
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: Dock content

    @ViewBuilder
    private func dockBody(_ tab: WorkspaceTab?) -> some View {
        switch tab {
        case .bible:
            BibleReaderView(vm: startup.bibleVM, notesVM: startup.notesVM, embedded: true).id(tab)
        case .agentChat:
            agentBody
        case .notes:
            NotesListView(vm: startup.notesVM, bibleVM: startup.bibleVM, embedded: true, fixedTab: .notes).id(tab)
        case .highlights:
            NotesListView(vm: startup.notesVM, bibleVM: startup.bibleVM, embedded: true, fixedTab: .highlights).id(tab)
        case .messages:
            ChatRootView(vm: startup.chatVM, embedded: true).id(tab)
        case nil:
            Color.clear
        }
    }

    @ViewBuilder
    private var agentBody: some View {
        if let agent = startup.chatVM.agents.first(where: { $0.id == agentId }) {
            AgentChatView(agent: agent, onBack: { agentId = nil }).id(agent.id)
        } else {
            AgentPickerList(vm: startup.chatVM, onSelect: { agentId = $0 }, onNew: { showNewAgent = true })
        }
    }
}

// MARK: - Tab pill

/// A dock tab. Long-press then drag moves it between docks; the "..." menu,
/// and the VoiceOver custom actions, do the same without dragging.
struct DockTabPill: View {
    let tab: WorkspaceTab
    let isActive: Bool
    let isDragged: Bool
    let actions: DockTabActions
    @GestureState private var lifted = false

    var body: some View {
        HStack(spacing: 0) {
            Text(tab.title)
                .font(.inter(Theme.fontXS, weight: .bold)).tracking(1)
                .foregroundColor(isActive ? Theme.parchment : Theme.textSecondary)
                .lineLimit(1).fixedSize()
                .padding(.leading, 14)
                .padding(.trailing, isActive ? 2 : 14)
            if isActive {
                Menu { menuItems } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold)).foregroundColor(Theme.goldLight)
                        .frame(width: 32, height: WorkspaceLayout.tabHitHeight).contentShape(Rectangle())
                }
                .accessibilityLabel("Options for \(tab.label) tab")
                Button(action: actions.close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold)).foregroundColor(Theme.goldLight)
                        .frame(width: 30, height: WorkspaceLayout.tabHitHeight).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(tab.label)")
            }
        }
        .frame(height: WorkspaceLayout.tabHitHeight)
        .background {
            if isActive {
                Capsule().fill(Theme.gold.opacity(0.16))
                    .overlay(Capsule().stroke(Theme.gold, lineWidth: 1))
                    .frame(height: WorkspaceLayout.tabPillHeight)
            }
        }
        .contentShape(Rectangle())
        .opacity(isDragged ? WorkspaceLayout.dragSourceOpacity : 1)
        .background(
            GeometryReader { g in
                Color.clear.preference(key: PillFramesKey.self, value: [tab: g.frame(in: .named(workspaceSpace))])
            }
        )
        .onTapGesture { actions.select() }
        .gesture(dragGesture)
        .onChange(of: lifted) { _, now in if !now { actions.cancel() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tab.label) tab")
        .accessibilityAddTraits(isActive ? .isSelected : .isButton)
        .accessibilityAction(.default) { actions.select() }
        .modifier(PillAccessibilityActions(actions: actions))
        .hoverEffect(.highlight)
    }

    private var dragGesture: some Gesture {
        LongPressGesture(minimumDuration: WorkspaceLayout.dragLiftDuration)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(workspaceSpace)))
            .updating($lifted) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                if case .second(true, let d) = value {
                    actions.lift()
                    if let d { actions.drag(d.location) }
                }
            }
            .onEnded { value in
                if case .second(true, let d?) = value { actions.drop(d.location) } else { actions.cancel() }
            }
    }

    @ViewBuilder
    private var menuItems: some View {
        ForEach(actions.destinations) { d in
            Button("Move to \(d.displayName)", systemImage: "arrow.up.right.square") { actions.move(d) }
        }
        if actions.canEarlier { Button("Move Earlier", systemImage: "arrow.left") { actions.nudge(-1) } }
        if actions.canLater { Button("Move Later", systemImage: "arrow.right") { actions.nudge(1) } }
        Button("Close", systemImage: "xmark") { actions.close() }
        Divider()
        Button("Reset layout", systemImage: "rectangle.3.group") { actions.reset() }
    }
}

/// VoiceOver / Switch Control custom actions mirroring the "..." menu.
private struct PillAccessibilityActions: ViewModifier {
    let actions: DockTabActions
    func body(content: Content) -> some View {
        var c = AnyView(content)
        for d in actions.destinations {
            c = AnyView(c.accessibilityAction(named: "Move to \(d.displayName)") { actions.move(d) })
        }
        if actions.canEarlier { c = AnyView(c.accessibilityAction(named: "Move Earlier") { actions.nudge(-1) }) }
        if actions.canLater { c = AnyView(c.accessibilityAction(named: "Move Later") { actions.nudge(1) }) }
        c = AnyView(c.accessibilityAction(named: "Close") { actions.close() })
        c = AnyView(c.accessibilityAction(named: "Reset layout") { actions.reset() })
        return c
    }
}

/// Floating preview that follows the finger during a drag.
private struct DragGhost: View {
    let tab: WorkspaceTab
    @ObservedObject var pointer: DragPointer
    var body: some View {
        Text(tab.title)
            .font(.inter(Theme.fontXS, weight: .bold)).tracking(1).foregroundColor(Theme.parchment)
            .padding(.horizontal, 16).frame(height: WorkspaceLayout.tabPillHeight)
            .background(Capsule().fill(WorkspaceLayout.ghostFill))
            .overlay(Capsule().stroke(Theme.gold, lineWidth: 1))
            .scaleEffect(WorkspaceLayout.dragGhostScale)
            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 6)
            .position(x: pointer.location.x, y: pointer.location.y - 36)
            .opacity(pointer.location == .zero ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Glass dock style

/// Frosted glass dock: page glow, ultra-thin material, dark tint, faint gold
/// border, soft top highlight. Reduce Transparency, Low Power Mode and the
/// portrait drawer use a solid fill instead (text contrast stays AA).
struct WorkspaceDockStyle: ViewModifier {
    let radius: CGFloat
    var isActive = false
    var drawer = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let solid = drawer || reduceTransparency || ProcessInfo.processInfo.isLowPowerModeEnabled
        let shape: AnyShape = drawer
            ? AnyShape(UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous))
            : AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        content
            .background {
                if solid {
                    shape.fill(WorkspaceLayout.dockSolid)
                } else {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(WorkspaceLayout.dockTint)
                    }
                }
            }
            .clipShape(shape)
            .overlay(shape.stroke(isActive ? WorkspaceLayout.activeDockBorder : Theme.borderGoldFaint, lineWidth: 1))
            .overlay(
                shape.stroke(LinearGradient(colors: [WorkspaceLayout.dockTopHighlight, .clear], startPoint: .top, endPoint: .center), lineWidth: 0.5)
            )
            .shadow(color: drawer ? WorkspaceLayout.drawerShadow : WorkspaceLayout.dockShadow,
                    radius: drawer ? 12 : 12, x: drawer ? -8 : 0, y: drawer ? 0 : 8)
    }
}

/// Agent chips + "+ New" and the empty state (screenshot 1 bottom panel).
struct AgentPickerList: View {
    @ObservedObject var vm: ChatViewModel
    let onSelect: (String) -> Void
    let onNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.agents) { agent in
                            Button { onSelect(agent.id) } label: {
                                Text(agent.displayLabel)
                                    .font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.parchment)
                                    .padding(.horizontal, 14).frame(minHeight: 36)
                                    .overlay(Capsule().stroke(Theme.borderGold, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Button(action: onNew) {
                    Text("+ New").font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.goldLight)
                        .padding(.horizontal, 8).frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New agent")
            }
            Spacer()
            Text("Choose an agent above to continue chatting.")
                .font(.inter(Theme.fontSM)).foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity)
            Spacer()
        }
        .padding(14)
    }
}
