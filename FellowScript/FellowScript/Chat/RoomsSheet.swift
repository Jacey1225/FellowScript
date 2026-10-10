// Discussion rooms sheet (task 20261009-discussion-rooms, frontend step 7,
// design-notes.md sections 1-3, 7). Presented from ChimeCallView exactly like
// RingMembersSheet (NavigationStack + warmBloomBackground + widgetCard,
// ghost-chip Close, [.medium, .large] detents). A sheet OVER the call: the
// call keeps running underneath. All logic that can be pure lives in
// CallRoomState.swift; this file is views + thin async glue.
//
// Room-switching itself is CallRoomController's job; this sheet only asks it.
// Copy comes from RoomCopy (never raw server text).

import SwiftUI

// MARK: - Shared small controls

/// Gold capsule action with a real 44pt hit area (PillButton's is ~40).
private struct RoomPillButton: View {
    let title: String
    var icon: String? = nil
    var minWidth: CGFloat = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .bold)).accessibilityHidden(true) }
                Text(title)
                    .font(.interScaled(Theme.fontSM, weight: .bold, relativeTo: .subheadline))
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .foregroundColor(Theme.ink)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .frame(minWidth: minWidth, minHeight: 44)
            .background(Theme.goldGradient)
            .clipShape(Capsule())
            .topEdgeHighlight(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct RoomGhostChip: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.interScaled(Theme.fontSM, relativeTo: .subheadline))
            .foregroundColor(Theme.textSecondary)
            .fixedSize()
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Capsule().fill(Theme.parchment.opacity(0.06)))
            .overlay(Capsule().stroke(Theme.parchment.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - Back to main pill + return-failed card (call screen header stack)

/// Pinned under the call header while in a room (design-notes.md section 4).
/// Same slot and left alignment as ScreenSharePill. Not dismissible.
struct BackToMainPill: View {
    let isReturning: Bool
    let roomName: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if isReturning {
                    ProgressView().controlSize(.small).tint(Theme.bgPage)
                } else {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 12, weight: .bold)).accessibilityHidden(true)
                }
                Text(isReturning ? "Returning\u{2026}" : "Back to main")
                    .font(.interScaled(Theme.fontXS, weight: .bold, relativeTo: .caption))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(Theme.bgPage)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(Capsule().fill(Theme.goldLight.opacity(0.9)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isReturning)
        .accessibilityLabel("Back to main session")
        .accessibilityHint("Leaves \(roomName) and returns to the main audio")
    }
}

/// Shown when returning to the main session failed. The CallKit call and the
/// room audio stay up the whole time (design-notes.md section 6).
struct RoomReturnFailedCard: View {
    let onRetry: () -> Void
    let onEnd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(RoomCopy.returnFailed)
                .font(.interScaled(Theme.fontSM, weight: .semibold, relativeTo: .subheadline))
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                RoomPillButton(title: "Try again", action: onRetry)
                Button(action: onEnd) {
                    Text("End call")
                        .font(.interScaled(Theme.fontSM, weight: .semibold, relativeTo: .subheadline))
                        .foregroundColor(Theme.error)
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .overlay(Capsule().stroke(Theme.error.opacity(0.6), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous).fill(Theme.bgPage.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous).stroke(Theme.borderGold, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Roster (invite picker source)

enum RoomRoster {
    /// Same sources as RingMembersSheet.loadRoster: a per-id user lookup over
    /// the group's member ids. Excludes the caller. A DM never reaches rooms.
    @MainActor
    static func load(session: FSSession, userId: String, service: DataServiceProtocol?) async -> [RingCandidate] {
        guard let service, !userId.isEmpty, !session.group_id.isEmpty, !RoomsFlag.isDirectMessage(session) else { return [] }
        guard let (_, groupMap) = try? await service.fetchContacts(userId: userId),
              let group = groupMap[session.group_id] else { return [] }
        let memberIds = group.users.filter { $0 != userId }
        let resolved = await withTaskGroup(of: RingCandidate?.self) { tg in
            for id in memberIds {
                tg.addTask {
                    guard let user = try? await service.fetchUser(userId: id) else { return nil }
                    return RingCandidate(id: id, name: user.username)
                }
            }
            var out: [RingCandidate] = []
            for await c in tg { if let c { out.append(c) } }
            return out
        }
        return resolved.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct InviteRow: View {
    let candidate: RingCandidate
    let selected: Bool
    let disabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 13) {
                AvatarView(initial: String(candidate.name.prefix(1)).uppercased(), diameter: 40,
                           fillColor: .clear, textColor: Theme.goldLight)
                    .background(Circle().fill(Theme.goldDim.opacity(0.35)))
                    .overlay(Circle().stroke(Theme.gold.opacity(0.5), lineWidth: 1))
                    .accessibilityHidden(true)
                Text(candidate.name)
                    .font(.interScaled(Theme.fontBody, relativeTo: .body))
                    .foregroundColor(Theme.parchment.opacity(disabled ? 0.45 : 0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? Theme.gold : Theme.parchment.opacity(0.35))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled && !selected)
        .accessibilityLabel(candidate.name)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Rooms sheet

struct RoomsSheet: View {
    let session: FSSession
    @ObservedObject var rooms: CallRoomController
    let userId: String
    let service: DataServiceProtocol?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var list: SessionRoomsListResponse?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var joiningId: String?
    @State private var rowErrors: [String: String] = [:]
    @State private var showCreate = false
    @State private var renameTarget: SessionRoom?
    @State private var inviteTarget: SessionRoom?
    @State private var endTarget: SessionRoom?
    @State private var manageError: String?
    @State private var candidates: [RingCandidate] = []

    private var visibleRooms: [SessionRoom] { RoomListLogic.visibleRooms(list?.rooms ?? []) }
    private var createBlock: RoomListLogic.CreateBlock? { RoomListLogic.createBlock(list) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingLG) {
                    if rooms.state.isInRoom || rooms.state.showsBackToMain { currentRoomCard }
                    createSection
                    if let manageError {
                        Text(manageError)
                            .font(.interScaled(Theme.fontXS, relativeTo: .caption))
                            .foregroundColor(Theme.error)
                            .accessibilityLabel(manageError)
                    }
                    roomsSection
                }
                .padding(Theme.spacingLG)
            }
            .refreshable { await refresh() }
            .warmBloomBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: { RoomGhostChip(title: "Close") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close rooms")
                }
                .suppressAutomaticGlassChrome()
                ToolbarItem(placement: .principal) {
                    Text("Rooms")
                        .font(.system(size: 17, weight: .semibold)).foregroundColor(Theme.parchment)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .navigationDestination(isPresented: $showCreate) {
                NewRoomPage(session: session, service: service, userId: userId,
                            maxInvites: RoomForm.maxInvites, onCreate: createRoom)
            }
            .accessibilityAction(.escape) { dismiss() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        // First fetch, then poll every 5s while the sheet is visible and the
        // app is active. .task cancels on dismiss; the id restarts it on resume.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(RoomHeartbeat.listPollInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await refresh()
            }
        }
        .sheet(item: $renameTarget) { room in
            RenameRoomSheet(room: room) { newTitle in await rename(room, to: newTitle) }
        }
        .sheet(item: $inviteTarget) { room in
            InvitePeopleSheet(session: session, room: room, service: service, userId: userId) { ids in
                await invite(room, ids)
            }
        }
        .confirmationDialog("End this room?", isPresented: Binding(get: { endTarget != nil }, set: { if !$0 { endTarget = nil } }),
                            titleVisibility: .visible, presenting: endTarget) { room in
            Button("End \(room.displayName)", role: .destructive) { Task { await end(room) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("Everyone in it goes back to the main session.") }
    }

    // MARK: Sections

    private var currentRoomCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("You\u{2019}re in \(rooms.state.currentRoomName ?? rooms.currentRoom?.displayName ?? "a room")")
                .font(.playfair(Theme.fontHeading)).foregroundColor(Theme.goldLight)
                .accessibilityAddTraits(.isHeader)
            if let r = rooms.currentRoom {
                Text("\(r.member_count) of \(r.max_members) here")
                    .font(.interScaled(Theme.fontXS, relativeTo: .caption))
                    .foregroundColor(Theme.textPrimary.opacity(0.85))
            }
            RoomPillButton(title: "Back to main", icon: "arrow.uturn.backward") {
                Task { await rooms.returnToMain(); if rooms.state == .main { dismiss() } }
            }
            .disabled(rooms.state.isBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetCard()
    }

    private var createSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showCreate = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 15, weight: .bold)).accessibilityHidden(true)
                    Text("Create a room")
                        .font(.interScaled(Theme.fontBody, weight: .bold, relativeTo: .body))
                }
                .foregroundColor(Theme.ink)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.goldGradient)
                .clipShape(Capsule())
                .topEdgeHighlight(Capsule())
                .opacity(createBlock == nil ? 1 : 0.5)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(createBlock != nil)
            .accessibilityHint("Starts a new discussion room")
            if let block = createBlock {
                Text(RoomListLogic.createBlockCaption(block))
                    .font(.interScaled(Theme.fontXS, relativeTo: .caption))
                    .foregroundColor(Theme.textPrimary.opacity(0.85))
            }
        }
    }

    @ViewBuilder private var roomsSection: some View {
        if isLoading && list == nil {
            ProgressView().tint(Theme.gold).frame(maxWidth: .infinity).padding(.top, Theme.spacingLG)
                .accessibilityLabel("Loading rooms")
        } else if loadFailed && list == nil {
            VStack(spacing: 8) {
                Text(RoomCopy.message(forCode: "network", action: .load))
                    .font(.interScaled(Theme.fontSM, relativeTo: .subheadline))
                    .foregroundColor(Theme.textPrimary.opacity(0.85))
                Button("Try again") { Task { await refresh() } }
                    .font(.interScaled(Theme.fontSM, weight: .semibold, relativeTo: .subheadline))
                    .foregroundColor(Theme.gold).frame(minHeight: 44)
            }
            .frame(maxWidth: .infinity)
        } else if visibleRooms.isEmpty {
            Text("No rooms yet. Start one to talk privately.")
                .font(.interScaled(Theme.fontSM, relativeTo: .subheadline))
                .foregroundColor(Theme.textPrimary.opacity(0.85))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.top, Theme.spacingSM)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(visibleRooms.enumerated()), id: \.element.id) { index, room in
                    RoomRow(room: room, isJoining: joiningId == room.id, error: rowErrors[room.id],
                            stacked: dynamicTypeSize.isAccessibilitySize,
                            onJoin: { join(room) },
                            onRename: { renameTarget = room },
                            onInvite: { inviteTarget = room },
                            onEnd: { endTarget = room })
                    if index < visibleRooms.count - 1 {
                        Rectangle().fill(Theme.borderGoldDim).frame(height: 1)
                    }
                }
            }
            .widgetCard()
        }
    }

    // MARK: Actions

    @MainActor
    private func refresh() async {
        guard let api = rooms.api else { isLoading = false; loadFailed = true; return }
        do {
            let result = try await api.listRooms(userId: userId, sessionId: session.id)
            list = result
            loadFailed = false
            rooms.noteRoomsList(result)
        } catch {
            if RoomCopy.isMainEnded(error) { rooms.onMainEnded?() }
            else if list == nil { loadFailed = true }   // keep the last good list on a poll blip
        }
        isLoading = false
    }

    private func join(_ room: SessionRoom) {
        guard joiningId == nil, !rooms.state.isBusy else { return }
        joiningId = room.id
        rowErrors[room.id] = nil
        Task { @MainActor in
            let error = await rooms.join(room: room)
            joiningId = nil
            if let error {
                rowErrors[room.id] = error
                await refresh()
            } else {
                dismiss()   // only once the new room is connected
            }
        }
    }

    /// Returns an inline error for the create page, or nil when it is done with.
    @MainActor
    private func createRoom(_ form: RoomForm) async -> String? {
        guard let api = rooms.api else { return RoomCopy.message(forCode: "network", action: .create) }
        do {
            let room = try await api.createRoom(userId: userId, sessionId: session.id,
                                                title: form.cleanName.isEmpty ? nil : form.cleanName,
                                                inviteOnly: form.inviteOnly, inviteeIds: form.effectiveInvitees)
            await refresh()
            if form.joinAfterCreate {
                if let error = await rooms.join(room: room) {
                    // The room exists: show the join error in its row.
                    rowErrors[room.id] = error
                    showCreate = false
                    return nil
                }
                dismiss()
                return nil
            }
            showCreate = false
            AccessibilityNotification.Announcement("\(room.displayName) created").post()
            return nil
        } catch {
            if RoomCopy.isMainEnded(error) { rooms.onMainEnded?(); return RoomCopy.mainEnded }
            if (error as? SessionRoomsError)?.code == "forbidden" { dismiss(); return nil }
            return RoomCopy.message(for: error, action: .create)
        }
    }

    @MainActor
    private func rename(_ room: SessionRoom, to title: String) async -> String? {
        guard let api = rooms.api else { return RoomCopy.message(forCode: "network", action: .manage) }
        do {
            try await api.renameRoom(userId: userId, roomId: room.id, title: title)
            manageError = nil
            await refresh()
            return nil
        } catch {
            return RoomCopy.message(for: error, action: .manage)
        }
    }

    @MainActor
    private func invite(_ room: SessionRoom, _ ids: [String]) async -> String? {
        guard let api = rooms.api else { return RoomCopy.message(forCode: "network", action: .manage) }
        do {
            try await api.inviteToRoom(userId: userId, roomId: room.id, inviteeIds: ids)
            manageError = nil
            await refresh()
            return nil
        } catch {
            return RoomCopy.message(for: error, action: .manage)
        }
    }

    @MainActor
    private func end(_ room: SessionRoom) async {
        guard let api = rooms.api else { return }
        do {
            try await api.endRoom(userId: userId, roomId: room.id)
            manageError = nil
            await rooms.didEndRoom(id: room.id)
            await refresh()
        } catch {
            manageError = RoomCopy.message(for: error, action: .manage)
        }
    }
}

// MARK: - Room row

private struct RoomRow: View {
    let room: SessionRoom
    let isJoining: Bool
    let error: String?
    let stacked: Bool
    let onJoin: () -> Void
    let onRename: () -> Void
    let onInvite: () -> Void
    let onEnd: () -> Void

    private var trailing: RoomTrailingState { RoomListLogic.trailing(for: room) }
    private var actions: [RoomListLogic.Action] { RoomListLogic.actions(for: room) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if stacked {
                    VStack(alignment: .leading, spacing: 8) { info; trailingControl }
                } else {
                    HStack(alignment: .center, spacing: 12) { info; Spacer(minLength: 8); trailingControl }
                }
            }
            if let error {
                Text(error)
                    .font(.interScaled(Theme.fontXS, relativeTo: .caption))
                    .foregroundColor(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.spacingSM)
        .frame(minHeight: stacked ? 0 : 56)
        .opacity(trailing == .full ? 0.55 : 1)
    }

    private var info: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: room.isInviteOnly ? "lock.fill" : "person.2.fill")
                .font(.system(size: 16)).foregroundColor(Theme.goldLight)
                .frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(room.displayName)
                    .font(.interScaled(Theme.fontBody, weight: .semibold, relativeTo: .body))
                    .foregroundColor(Theme.textPrimary).lineLimit(2)
                Text(RoomListLogic.subtitle(for: room))
                    .font(.interScaled(Theme.fontXS, relativeTo: .caption))
                    .foregroundColor(Theme.textPrimary.opacity(0.85))
                if !stacked, let names = RoomListLogic.memberNames(room) {
                    Text(names)
                        .font(.interScaled(Theme.fontXS, relativeTo: .caption))
                        .foregroundColor(Theme.textPrimary.opacity(0.85)).lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(room.displayName), \(room.isInviteOnly ? "invite only" : "open")")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(trailing == .join || trailing == .invitedJoin ? "Use the Join button to enter" : "")
    }

    private var accessibilityValue: String {
        var parts = ["\(room.member_count) of \(room.max_members) people"]
        switch trailing {
        case .full: parts.append("Full")
        case .here: parts.append("You\u{2019}re here")
        case .invitedJoin: parts.append("Invited")
        default: break
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var trailingControl: some View {
        HStack(spacing: 8) {
            switch trailing {
            case .here:
                Label("You\u{2019}re here", systemImage: "checkmark.circle.fill")
                    .font(.interScaled(Theme.fontXS, weight: .semibold, relativeTo: .caption))
                    .foregroundColor(Theme.goldLight)
                    .frame(minHeight: 44)
            case .full:
                Label("Full", systemImage: "person.2.slash")
                    .font(.interScaled(Theme.fontXS, weight: .semibold, relativeTo: .caption))
                    .foregroundColor(Theme.textPrimary.opacity(0.85))
                    .frame(minHeight: 44)
            case .hidden:
                EmptyView()
            case .invitedJoin, .join:
                if trailing == .invitedJoin {
                    Text("Invited")
                        .font(.interScaled(Theme.fontXS, weight: .bold, relativeTo: .caption))
                        .foregroundColor(Theme.bgPage)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.gold))
                        .accessibilityHidden(true)
                }
                if isJoining {
                    ProgressView().tint(Theme.gold).frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Joining \(room.displayName)")
                } else {
                    RoomPillButton(title: "Join", minWidth: 64, action: onJoin)
                        .accessibilityLabel("Join \(room.displayName)")
                }
            }
            if !actions.isEmpty {
                Menu {
                    if actions.contains(.rename) { Button("Rename room", action: onRename) }
                    if actions.contains(.invite) { Button("Invite people", action: onInvite) }
                    if actions.contains(.end) { Button("End room", role: .destructive, action: onEnd) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20)).foregroundColor(Theme.goldLight)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("More actions for \(room.displayName)")
            }
        }
    }
}

// MARK: - Create page

private struct NewRoomPage: View {
    let session: FSSession
    let service: DataServiceProtocol?
    let userId: String
    let maxInvites: Int
    let onCreate: (RoomForm) async -> String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var form = RoomForm()
    @State private var candidates: [RingCandidate] = []
    @State private var loadingRoster = false
    @State private var submitting = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacingLG) {
                nameSection
                whoSection
                if form.inviteOnly { inviteSection }
                Toggle(isOn: $form.joinAfterCreate) {
                    Text("Join after creating")
                        .font(.interScaled(Theme.fontBody, relativeTo: .body)).foregroundColor(Theme.textPrimary)
                }
                .tint(Theme.gold)
                .frame(minHeight: 44)
                if let errorText {
                    Text(errorText)
                        .font(.interScaled(Theme.fontXS, relativeTo: .caption))
                        .foregroundColor(Theme.error)
                        .accessibilityLabel(errorText)
                }
                Button { submit() } label: {
                    Group {
                        if submitting { ProgressView().tint(Theme.ink) }
                        else { Text("Create room").font(.interScaled(Theme.fontBody, weight: .bold, relativeTo: .body)) }
                    }
                    .foregroundColor(Theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.goldGradient)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(submitting)
                .accessibilityLabel("Create room")
            }
            .padding(Theme.spacingLG)
        }
        .warmBloomBackground()
        .navigationTitle("New room")
        .navigationBarTitleDisplayMode(.inline)
        .presentationDetents([.large])
        .task(id: form.inviteOnly) {
            guard form.inviteOnly, candidates.isEmpty else { return }
            loadingRoster = true
            candidates = await RoomRoster.load(session: session, userId: userId, service: service)
            loadingRoster = false
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Room name (optional)", text: $form.name)
                .textInputAutocapitalization(.words)
                .font(.interScaled(Theme.fontBody, relativeTo: .body))
                .foregroundColor(Theme.textPrimary)
                .padding(.horizontal, 14).frame(minHeight: 48)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.goldDim.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.borderGoldDim, lineWidth: 1))
                .onChange(of: form.name) { _, new in
                    if new.count > RoomForm.maxNameLength { form.name = String(new.prefix(RoomForm.maxNameLength)) }
                }
                .accessibilityLabel("Room name")
                .accessibilityHint("Optional. Leave blank to use the default name")
            HStack {
                Text("Leave blank for \u{201C}Room N\u{201D}")
                    .font(.interScaled(Theme.fontXS, relativeTo: .caption))
                    .foregroundColor(Theme.textPrimary.opacity(0.85))
                Spacer()
                if form.showsCounter {
                    Text("\(form.name.count)/\(RoomForm.maxNameLength)")
                        .font(.interScaled(Theme.fontXS, relativeTo: .caption))
                        .foregroundColor(Theme.textPrimary.opacity(0.85))
                }
            }
        }
    }

    private var whoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Who can join", selection: $form.inviteOnly) {
                Text("Open").tag(false)
                Text("Invite only").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
            .accessibilityLabel("Who can join")
            .accessibilityValue(form.inviteOnly ? "Invite only" : "Open")
            Text(form.inviteOnly ? "Only people you choose can join" : "Anyone in this session can join")
                .font(.interScaled(Theme.fontXS, relativeTo: .caption))
                .foregroundColor(Theme.textPrimary.opacity(0.85))
        }
    }

    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(form.invitees.count) selected")
                .font(.interScaled(Theme.fontXS, weight: .semibold, relativeTo: .caption))
                .foregroundColor(Theme.textPrimary.opacity(0.85))
            if loadingRoster {
                ProgressView().tint(Theme.gold).frame(maxWidth: .infinity)
            } else if candidates.isEmpty {
                Text("No other members to invite.")
                    .font(.interScaled(Theme.fontSM, relativeTo: .subheadline))
                    .foregroundColor(Theme.textPrimary.opacity(0.85))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, c in
                        InviteRow(candidate: c, selected: form.invitees.contains(c.id),
                                  disabled: form.atInviteCap) { form.toggleInvitee(c.id) }
                        if index < candidates.count - 1 { Divider().opacity(0.15) }
                    }
                }
                .widgetCard()
                if form.atInviteCap {
                    Text("Invitation limit reached")
                        .font(.interScaled(Theme.fontXS, relativeTo: .caption)).foregroundColor(Theme.textPrimary.opacity(0.85))
                }
            }
            if form.invitees.isEmpty {
                Text("You can invite people after creating the room.")
                    .font(.interScaled(Theme.fontXS, relativeTo: .caption)).foregroundColor(Theme.textPrimary.opacity(0.85))
            }
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        .motionAwareAnimation(.spring(response: 0.35, dampingFraction: 0.82), value: form.inviteOnly, reduceMotion: reduceMotion)
    }

    private func submit() {
        guard !submitting else { return }
        submitting = true; errorText = nil
        let snapshot = form
        Task { @MainActor in
            let error = await onCreate(snapshot)
            submitting = false
            errorText = error
        }
    }
}

// MARK: - Rename sheet

private struct RenameRoomSheet: View {
    let room: SessionRoom
    let onSave: (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var errorText: String?

    init(room: SessionRoom, onSave: @escaping (String) async -> String?) {
        self.room = room
        self.onSave = onSave
        _text = State(initialValue: room.title)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Room name", text: $text)
                    .textInputAutocapitalization(.words)
                    .font(.interScaled(Theme.fontBody, relativeTo: .body)).foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 14).frame(minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.goldDim.opacity(0.18)))
                    .onChange(of: text) { _, new in
                        if new.count > RoomForm.maxNameLength { text = String(new.prefix(RoomForm.maxNameLength)) }
                    }
                    .accessibilityLabel("Room name")
                HStack {
                    Text("Leave blank to use \u{201C}Room N\u{201D}")
                        .font(.interScaled(Theme.fontXS, relativeTo: .caption)).foregroundColor(Theme.textPrimary.opacity(0.85))
                    Spacer()
                    if text.count >= RoomForm.counterThreshold {
                        Text("\(text.count)/\(RoomForm.maxNameLength)")
                            .font(.interScaled(Theme.fontXS, relativeTo: .caption)).foregroundColor(Theme.textPrimary.opacity(0.85))
                    }
                }
                if let errorText {
                    Text(errorText).font(.interScaled(Theme.fontXS, relativeTo: .caption)).foregroundColor(Theme.error)
                }
                Spacer()
            }
            .padding(Theme.spacingLG)
            .warmBloomBackground()
            .navigationTitle("Rename room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: { RoomGhostChip(title: "Cancel") }.buttonStyle(.plain)
                }
                .suppressAutomaticGlassChrome()
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { save() } label: {
                        if saving { ProgressView().tint(Theme.gold) }
                        else { Text("Save").font(.interScaled(Theme.fontSM, weight: .bold, relativeTo: .subheadline)).foregroundColor(Theme.gold) }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(saving)
                }
                .suppressAutomaticGlassChrome()
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
        .accessibilityAction(.escape) { dismiss() }
    }

    private func save() {
        saving = true; errorText = nil
        let cleaned = RoomForm.clean(text)
        Task { @MainActor in
            let error = await onSave(cleaned)
            saving = false
            if let error { errorText = error } else { dismiss() }
        }
    }
}

// MARK: - Invite people sheet (invite-only rooms, creator or live member)

private struct InvitePeopleSheet: View {
    let session: FSSession
    let room: SessionRoom
    let service: DataServiceProtocol?
    let userId: String
    let onSend: ([String]) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [RingCandidate] = []
    @State private var loading = true
    @State private var picked: Set<String> = []
    @State private var sending = false
    @State private var errorText: String?

    private var memberIds: Set<String> { Set(room.members.map(\.user_id)) }
    private var atCap: Bool { picked.count >= RoomForm.maxInvites }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if loading {
                        ProgressView().tint(Theme.gold).frame(maxWidth: .infinity)
                    } else if candidates.isEmpty {
                        Text("No other members to invite.")
                            .font(.interScaled(Theme.fontSM, relativeTo: .subheadline))
                            .foregroundColor(Theme.textPrimary.opacity(0.85))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, c in
                                InviteRow(candidate: c, selected: picked.contains(c.id), disabled: atCap) {
                                    if picked.contains(c.id) { picked.remove(c.id) } else if !atCap { picked.insert(c.id) }
                                }
                                if index < candidates.count - 1 { Divider().opacity(0.15) }
                            }
                        }
                        .widgetCard()
                    }
                    if let errorText {
                        Text(errorText).font(.interScaled(Theme.fontXS, relativeTo: .caption)).foregroundColor(Theme.error)
                    }
                }
                .padding(Theme.spacingLG)
            }
            .warmBloomBackground()
            .navigationTitle("Invite people")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: { RoomGhostChip(title: "Cancel") }.buttonStyle(.plain)
                }
                .suppressAutomaticGlassChrome()
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { send() } label: {
                        if sending { ProgressView().tint(Theme.gold) }
                        else {
                            Text(picked.isEmpty ? "Invite" : "Invite (\(picked.count))")
                                .font(.interScaled(Theme.fontSM, weight: .bold, relativeTo: .subheadline))
                                .foregroundColor(Theme.gold)
                        }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(picked.isEmpty || sending)
                }
                .suppressAutomaticGlassChrome()
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
        .accessibilityAction(.escape) { dismiss() }
        .task {
            let all = await RoomRoster.load(session: session, userId: userId, service: service)
            candidates = all.filter { !memberIds.contains($0.id) }
            loading = false
        }
    }

    private func send() {
        sending = true; errorText = nil
        let ids = Array(picked).sorted()
        Task { @MainActor in
            let error = await onSend(ids)
            sending = false
            if let error { errorText = error } else { dismiss() }
        }
    }
}
