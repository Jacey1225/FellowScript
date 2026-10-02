// GroupInfoSheet.swift — group info panel (task 20260929-group-info-panel,
// design-notes.md). Presented as a bottom sheet from ChatThreadView's header
// for group chats only. Rename, group photo (change / remove with undo),
// per-user mute, hosted member list, and a paged attachment gallery.
//
// Failure behavior (throw-not-fabricate, preserve-cache-on-failed-refresh):
// every network call throws; mute state always shows the last
// server-confirmed value; a failed refresh keeps the cached info/gallery and
// shows a slim banner instead of blanking anything.

import SwiftUI
import PhotosUI
import Combine

// ── Limits (advisory client-side pre-flight; S3 policy is the real enforcement) ─
enum GroupPhotoLimits {
    static let maxBytes = 15 * 1024 * 1024
    static let allowedContentTypes: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/heic"]
    static let oversizeCopy = "Photos can be up to 15MB."
    static let unsupportedTypeCopy = "Choose a JPG, PNG, or WebP under 15MB."
}

enum GroupGalleryFilter: String, CaseIterable, Identifiable {
    case all, image, video, gif, file
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .image: return "Photos"
        case .video: return "Videos"
        case .gif: return "GIFs"
        case .file: return "Files"
        }
    }
    /// Server `kind` query value; nil = every kind.
    var kind: String? { self == .all ? nil : rawValue }
    var emptyCopy: String {
        switch self {
        case .all: return "Nothing shared yet. Photos, GIFs, and files from this group will gather here."
        case .image: return "No photos yet."
        case .video: return "No videos yet."
        case .gif: return "No GIFs yet."
        case .file: return "No files yet."
        }
    }
}

// ── View model ───────────────────────────────────────────────────────────────
@MainActor
final class GroupInfoViewModel: ObservableObject {
    let groupId: String
    let userId:  String
    private let service: DataServiceProtocol

    @Published var info: FSGroupInfo?
    @Published var refreshFailed = false
    @Published var nameError: String?
    @Published var photoError: String?
    @Published var muteError: String?
    @Published var capError: String?
    @Published var savingCap = false
    @Published var capSaved = false
    @Published var savingName = false
    @Published var photoBusy = false
    @Published var mutePending = false
    @Published var photoJustUpdated = false
    @Published var undoRestoreKey: String?
    @Published var removedFromGroup = false

    @Published var filter: GroupGalleryFilter = .all
    @Published var galleryItems: [FSGalleryItem] = []
    @Published var galleryLoaded = false
    @Published var galleryLoading = false
    @Published var galleryError: String?
    private var galleryCursor: (timestamp: String, id: String)?
    @Published var galleryHasMore = false

    /// Set when a server-confirmed change should propagate to the chat header/list.
    var onTitleChanged: ((String) -> Void)?
    var onPhotoChanged: ((String?) -> Void)?

    private var undoTask: Task<Void, Never>?

    init(service: DataServiceProtocol, groupId: String, userId: String) {
        self.service = service
        self.groupId = groupId
        self.userId  = userId
    }

    private var infoKey: String { "groupinfo_\(userId)_\(groupId)" }
    private func galleryKey(_ f: GroupGalleryFilter) -> String { "groupgallery_\(userId)_\(groupId)_\(f.rawValue)" }

    /// True for the server's 403 "Not a member" (AppError has no status code).
    private func isNotMember(_ error: Error) -> Bool {
        if case AppError.networkError(let m) = error { return m.localizedCaseInsensitiveContains("not a member") }
        return false
    }

    private func message(_ error: Error, fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? fallback
    }

    // Cached first, then refresh. A failed refresh keeps whatever is cached.
    func loadInfo() async {
        if info == nil, let cached = await DiskCache.shared.load(FSGroupInfo.self, forKey: infoKey) { info = cached }
        do {
            let fresh = try await service.fetchGroupInfo(userId: userId, groupId: groupId)
            info = fresh
            refreshFailed = false
            await DiskCache.shared.save(fresh, forKey: infoKey)
        } catch {
            if isNotMember(error) { removedFromGroup = true } else { refreshFailed = true }
        }
    }

    func loadGalleryFirstPage() async {
        let f = filter
        if let cached = await DiskCache.shared.load(FSGalleryPage.self, forKey: galleryKey(f)), !galleryLoaded {
            apply(page: cached, replacing: true)
        }
        galleryLoading = true
        galleryError = nil
        defer { galleryLoading = false }
        do {
            let page = try await service.fetchGroupGallery(userId: userId, groupId: groupId, kind: f.kind, cursorTimestamp: nil, cursorId: nil)
            guard f == filter else { return }   // filter changed mid-flight
            apply(page: page, replacing: true)
            await DiskCache.shared.save(page, forKey: galleryKey(f))
        } catch {
            if isNotMember(error) { removedFromGroup = true }
            else if f == filter { galleryError = message(error, fallback: "Couldn't load shared items.") }
        }
    }

    func loadMore() async {
        guard let cursor = galleryCursor, !galleryLoading else { return }
        let f = filter
        galleryLoading = true
        galleryError = nil
        defer { galleryLoading = false }
        do {
            let page = try await service.fetchGroupGallery(userId: userId, groupId: groupId, kind: f.kind, cursorTimestamp: cursor.timestamp, cursorId: cursor.id)
            guard f == filter else { return }
            apply(page: page, replacing: false)
        } catch {
            if isNotMember(error) { removedFromGroup = true }
            else { galleryError = message(error, fallback: "Couldn't load more.") }
        }
    }

    private func apply(page: FSGalleryPage, replacing: Bool) {
        galleryItems = replacing ? page.items : galleryItems + page.items
        galleryHasMore = page.has_more
        if page.has_more, let ts = page.next_cursor_timestamp, let id = page.next_cursor_id {
            galleryCursor = (ts, id)
        } else {
            galleryCursor = nil
        }
        galleryLoaded = true
    }

    func selectFilter(_ f: GroupGalleryFilter) async {
        guard f != filter else { return }
        filter = f
        galleryItems = []
        galleryCursor = nil
        galleryHasMore = false
        galleryLoaded = false
        await loadGalleryFirstPage()
    }

    /// Returns true on success so the view can leave edit mode.
    func rename(to raw: String) async -> Bool {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !savingName else { return false }
        savingName = true
        nameError = nil
        defer { savingName = false }
        do {
            let saved = try await service.renameGroup(userId: userId, groupId: groupId, title: title)
            info?.title = saved
            if let info { await DiskCache.shared.save(info, forKey: infoKey) }
            onTitleChanged?(saved)
            return true
        } catch {
            if isNotMember(error) { removedFromGroup = true }
            else { nameError = message(error, fallback: "That name didn't save. Please try again.") }
            return false
        }
    }

    /// Owner only. nil clears the cap. Returns true on a server-confirmed save.
    func setMaxMembers(_ value: Int?) async -> Bool {
        guard !savingCap else { return false }
        savingCap = true
        capError = nil
        capSaved = false
        defer { savingCap = false }
        do {
            let confirmed = try await service.setGroupMaxMembers(userId: userId, groupId: groupId, maxMembers: value)
            info?.max_members = confirmed
            if let info { await DiskCache.shared.save(info, forKey: infoKey) }
            capSaved = true
            return true
        } catch {
            if isNotMember(error) { removedFromGroup = true }
            else { capError = message(error, fallback: "Couldn't save the limit. Please try again.") }
            return false
        }
    }

    func setMuted(_ muted: Bool) async {
        guard !mutePending else { return }
        mutePending = true
        muteError = nil
        defer { mutePending = false }
        do {
            let confirmed = try await service.setGroupMuted(userId: userId, groupId: groupId, muted: muted)
            info?.muted = confirmed
            if let info { await DiskCache.shared.save(info, forKey: infoKey) }
        } catch {
            if isNotMember(error) { removedFromGroup = true }
            else { muteError = "Couldn't update notifications. Please try again." }
        }
    }

    func uploadPhoto(data: Data, contentType: String) async {
        photoError = nil
        guard data.count <= GroupPhotoLimits.maxBytes else { photoError = GroupPhotoLimits.oversizeCopy; return }
        guard GroupPhotoLimits.allowedContentTypes.contains(contentType) else { photoError = GroupPhotoLimits.unsupportedTypeCopy; return }
        photoBusy = true
        undoTask?.cancel(); undoRestoreKey = nil
        defer { photoBusy = false }
        do {
            let upload = try await service.requestGroupPhotoUploadURL(userId: userId, groupId: groupId, contentType: contentType, sizeBytes: data.count)
            try await service.uploadAttachment(fileData: data, contentType: contentType, uploadInfo: upload)
            let url = try await service.confirmGroupPhoto(userId: userId, groupId: groupId, objectKey: upload.object_key)
            applyPhoto(url)
        } catch {
            if isNotMember(error) { removedFromGroup = true }
            else { photoError = message(error, fallback: "Upload failed. Please try again.") }
        }
    }

    func removePhoto() async {
        photoError = nil
        photoBusy = true
        defer { photoBusy = false }
        do {
            let restoreKey = try await service.removeGroupPhoto(userId: userId, groupId: groupId)
            applyPhoto(nil)
            if let restoreKey {
                undoRestoreKey = restoreKey
                undoTask?.cancel()
                undoTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.undoRestoreKey = nil
                }
            }
        } catch {
            if isNotMember(error) { removedFromGroup = true }
            else { photoError = message(error, fallback: "Couldn't remove the photo. Please try again.") }
        }
    }

    func undoRemove() async {
        guard let key = undoRestoreKey else { return }
        undoTask?.cancel()
        undoRestoreKey = nil
        photoBusy = true
        defer { photoBusy = false }
        do {
            let url = try await service.confirmGroupPhoto(userId: userId, groupId: groupId, objectKey: key)
            applyPhoto(url)
        } catch {
            if isNotMember(error) { removedFromGroup = true }
            else { photoError = "Couldn't restore the photo. Please choose it again." }
        }
    }

    private func applyPhoto(_ url: String?) {
        info?.photo_url = url
        if let info { Task { await DiskCache.shared.save(info, forKey: infoKey) } }
        onPhotoChanged?(url)
        photoJustUpdated = true
        Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            photoJustUpdated = false
        }
    }

}

// ── Sheet ────────────────────────────────────────────────────────────────────
struct GroupInfoSheet: View {
    let contact: FSContact
    let user: FSUser?
    let memberNames: [String]
    let photoByUsername: [String: String]
    var onAddMembers: (() -> Void)?
    var onGroupGone: () -> Void

    @StateObject private var vm: GroupInfoViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var editingName = false
    @State private var draftName = ""
    @State private var capDraft = ""
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showPhotoActions = false
    @State private var showPhotoPicker = false
    @State private var viewerItem: FSGalleryItem?
    @State private var showAnnouncements = false
    private let service: DataServiceProtocol

    init(contact: FSContact, user: FSUser?, service: DataServiceProtocol,
         memberNames: [String], photoByUsername: [String: String],
         onTitleChanged: @escaping (String) -> Void,
         onPhotoChanged: @escaping (String?) -> Void,
         onAddMembers: (() -> Void)? = nil,
         onGroupGone: @escaping () -> Void) {
        self.contact = contact
        self.user = user
        self.memberNames = memberNames
        self.photoByUsername = photoByUsername
        self.onAddMembers = onAddMembers
        self.onGroupGone = onGroupGone
        self.service = service
        let model = GroupInfoViewModel(service: service, groupId: contact.id, userId: user?.user_id ?? "")
        model.onTitleChanged = onTitleChanged
        model.onPhotoChanged = onPhotoChanged
        _vm = StateObject(wrappedValue: model)
    }

    private var title: String { vm.info?.title ?? contact.name }
    private var photoURL: String? { vm.info != nil ? vm.info?.photo_url : contact.photoUrl }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        NavigationStack {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.spacingLG) {
                        if vm.refreshFailed { refreshBanner }
                        identityBlock
                        muteRow
                        if GroupAnnouncementsConfig.enabled { announcementsRow }
                        // Task 20260929-group-invite-links: hides itself when the
                        // backend feature flag is off (uniform 404 from list).
                        InviteLinkSection(
                            service: service, groupId: contact.id, userId: user?.user_id ?? "",
                            onGroupGone: { dismiss(); onGroupGone() }
                        )
                        memberLimitSection
                        GroupInfoExtraSectionsView(context: .init(
                            service: service, groupId: contact.id, userId: user?.user_id ?? "",
                            isOwner: vm.info?.is_owner ?? false))
                        membersSection
                        sharedSection
                    }
                    .padding(.horizontal, Theme.spacingMD)
                    .padding(.bottom, Theme.spacingXL)
                }
            }
            if vm.undoRestoreKey != nil { undoToast }
        }
        // Same warm bloom ground as the chat screen (shared recipe).
        .warmBloomBackground()
        // Announcements pushes onto this stack; the sheet keeps its own top bar.
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showAnnouncements) {
            GroupAnnouncementsView(
                service: service, groupId: contact.id, userId: user?.user_id ?? "",
                onGroupGone: { dismiss(); onGroupGone() }
            )
        }
        }
        // "See plans" on the announcements limit card: close the sheet so the
        // Account tab (switched by ContentView) is visible.
        .onReceive(NotificationCenter.default.publisher(for: .fsOpenSubscriptionPlans)) { _ in dismiss() }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await vm.loadInfo() }
        .task { await vm.loadGalleryFirstPage() }
        .onChange(of: vm.removedFromGroup) { _, gone in
            if gone { dismiss(); onGroupGone() }
        }
        .onChange(of: photoPickerItem) { _, item in handlePicked(item) }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItem, matching: .images, photoLibrary: .shared())
        .confirmationDialog("Group photo", isPresented: $showPhotoActions, titleVisibility: .hidden) {
            Button("Choose photo") { showPhotoPicker = true }
            Button("Remove photo", role: .destructive) { Task { await vm.removePhoto() } }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(item: $viewerItem) { item in GroupGalleryViewer(item: item) { viewerItem = nil } }
    }

    // ── Sections ─────────────────────────────────────────────────────────────
    private var topBar: some View {
        HStack {
            Text("GROUP INFO")
                .font(.inter(Theme.fontXS, weight: .bold)).tracking(3)
                .foregroundColor(Theme.gold.opacity(0.85))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.gold)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close group info")
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.top, Theme.spacingSM)
    }

    private var refreshBanner: some View {
        HStack {
            Text("Couldn't refresh just now. Showing what we have.")
                .font(.inter(Theme.fontXS))
                .foregroundColor(Theme.parchment.opacity(0.85))
            Spacer()
            Button("Try again") { Task { await vm.loadInfo() } }
                .font(.inter(Theme.fontXS, weight: .semibold))
                .foregroundColor(Theme.gold)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, Theme.spacingSM)
        .background(Theme.gold.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    private var identityBlock: some View {
        VStack(spacing: Theme.spacingSM) {
            Button {
                if photoURL != nil { showPhotoActions = true } else { showPhotoPicker = true }
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(
                        initial: String(title.prefix(1)).uppercased(),
                        photoURL: photoURL,
                        diameter: 96,
                        fillColor: Theme.gold.opacity(0.12),
                        textColor: Theme.gold
                    )
                    .opacity(vm.photoBusy ? 0.4 : 1)
                    .scaleEffect(vm.photoJustUpdated && !reduceMotion ? 1.05 : 1.0)
                    .motionAwareAnimation(.easeOut(duration: 0.2), value: vm.photoJustUpdated, reduceMotion: reduceMotion)
                    .overlay { if vm.photoBusy { ProgressView().tint(Theme.gold) } }

                    Image(systemName: "camera.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Theme.ink)
                        .frame(width: 28, height: 28)
                        .background(Theme.gold)
                        .clipShape(Circle())
                }
                .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(vm.photoBusy)
            .accessibilityLabel("Change group photo")

            if let err = vm.photoError { errorText(err) }

            if editingName {
                VStack(spacing: Theme.spacingXS) {
                    TextField("Group name", text: $draftName)
                        .font(.inter(Theme.fontSM))
                        .foregroundColor(Theme.parchment)
                        .padding(.horizontal, Theme.spacingSM)
                        .frame(minHeight: 44)
                        .background(Theme.cardBg)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderGoldDim, lineWidth: 1))
                        .disabled(vm.savingName)
                        .onChange(of: draftName) { _, v in if v.count > 255 { draftName = String(v.prefix(255)) } }
                        .onSubmit { saveName() }
                        .accessibilityLabel("Group name")
                    if draftName.count >= 230 {
                        Text("\(draftName.count)/255")
                            .font(.inter(Theme.fontXXS)).foregroundColor(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    if draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Give the group a name.").font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                    }
                    if let err = vm.nameError { errorText(err) }
                    HStack(spacing: Theme.spacingSM) {
                        PillButton(title: vm.savingName ? "Saving…" : "Save") { saveName() }
                            .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.savingName)
                        Button("Cancel") { editingName = false; vm.nameError = nil }
                            .font(.inter(Theme.fontSM)).foregroundColor(Theme.gold)
                            .frame(minHeight: 44)
                            .disabled(vm.savingName)
                    }
                }
            } else {
                Text(title)
                    .font(.inter(Theme.fontHeading, weight: .bold))
                    .foregroundColor(Theme.parchment)
                    .multilineTextAlignment(.center)
                Button {
                    draftName = title; vm.nameError = nil; editingName = true
                } label: {
                    Label("Edit name", systemImage: "pencil")
                        .font(.inter(Theme.fontSM)).foregroundColor(Theme.gold)
                        .frame(minHeight: 44)
                }
                .accessibilityLabel("Edit group name")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var muteRow: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            HStack(spacing: Theme.spacingSM) {
                Image(systemName: vm.info?.muted == true ? "bell.slash.fill" : "bell.fill")
                    .foregroundColor(Theme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mute notifications").font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                    Text("You will still get messages here, just no alerts.")
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                }
                Spacer()
                if vm.mutePending {
                    ProgressView().tint(Theme.gold)
                } else if let info = vm.info {
                    Toggle("Mute notifications", isOn: Binding(
                        get: { info.muted },
                        set: { newValue in Task { await vm.setMuted(newValue) } }
                    ))
                    .labelsHidden()
                    .tint(Theme.gold)
                } else {
                    Capsule().fill(Color.white.opacity(0.12)).frame(width: 48, height: 26)
                        .accessibilityHidden(true)
                }
            }
            .padding(Theme.spacingSM)
            .frame(minHeight: 56)
            if let err = vm.muteError { errorText(err) }
        }
    }

    // Task 20260929-group-announcements: entry row -> Announcements sub-view.
    private var announcementsRow: some View {
        Button { showAnnouncements = true } label: {
            HStack(spacing: Theme.spacingSM) {
                Image(systemName: "megaphone.fill").foregroundColor(Theme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Announcements").font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                    Text("Updates for everyone in this group.")
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textSecondary)
            }
            .padding(Theme.spacingSM)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Announcements")
    }

    // Task 20260930-group-invite-permanent-member-cap. Owner edits the limit;
    // everyone else sees it read-only (or nothing when there is none).
    @ViewBuilder
    private var memberLimitSection: some View {
        if let info = vm.info, info.is_owner || info.max_members != nil {
            let current = info.max_members.map(String.init) ?? ""
            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                sectionLabel("Member limit")
                if info.is_owner {
                    Text("Most people allowed in this group. Leave blank for no limit.")
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                    TextField("No limit", text: $capDraft)
                        .keyboardType(.numberPad)
                        .font(.inter(Theme.fontSM))
                        .foregroundColor(Theme.parchment)
                        .padding(.horizontal, Theme.spacingSM)
                        .frame(minHeight: 44)
                        .background(Theme.cardBg)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderGoldDim, lineWidth: 1))
                        .disabled(vm.savingCap)
                        .onChange(of: capDraft) { _, v in
                            let digits = String(v.filter(\.isNumber).prefix(6))
                            if digits != v { capDraft = digits }
                            vm.capError = nil; vm.capSaved = false
                        }
                        .accessibilityLabel("Maximum members")
                    if let ceiling = info.max_members_ceiling {
                        Text("Up to \(ceiling). Not lower than the \(info.member_count ?? info.members.count) people here now.")
                            .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                    }
                    if let err = vm.capError { errorText(err) }
                    if vm.capSaved {
                        Text("Limit saved.").font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                            .accessibilityLabel("Member limit saved")
                    }
                    PillButton(title: vm.savingCap ? "Saving…" : "Save limit") {
                        let trimmed = capDraft.trimmingCharacters(in: .whitespaces)
                        Task { _ = await vm.setMaxMembers(trimmed.isEmpty ? nil : Int(trimmed)) }
                    }
                    .disabled(vm.savingCap || capDraft.trimmingCharacters(in: .whitespaces) == current)
                } else if let cap = info.max_members {
                    Text("Up to \(cap) people can be in this group.")
                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { capDraft = current }
            .onChange(of: current) { _, v in capDraft = v }
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            GroupMembersPanel(
                memberNames: memberNames,
                user: user,
                photoByUsername: photoByUsername,
                onAddTapped: onAddMembers.map { add in { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { add() } } }
            )
        }
    }

    private var sharedSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            sectionLabel("Shared")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.spacingSM) {
                    ForEach(GroupGalleryFilter.allCases) { f in
                        Button { Task { await vm.selectFilter(f) } } label: {
                            Text(f.label)
                                .font(.inter(Theme.fontXS, weight: .semibold))
                                .foregroundColor(vm.filter == f ? Theme.gold : Theme.parchment.opacity(0.8))
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)
                                .background(vm.filter == f ? Theme.gold.opacity(0.15) : Color.clear)
                                .overlay(Capsule().stroke(vm.filter == f ? Theme.borderGold : Theme.borderGoldDim, lineWidth: 1))
                                .clipShape(Capsule())
                        }
                        .accessibilityLabel(f.label)
                        .accessibilityAddTraits(vm.filter == f ? .isSelected : [])
                    }
                }
            }

            if !vm.galleryLoaded && vm.galleryLoading {
                RoundedRectangle(cornerRadius: Theme.radius).fill(Color.white.opacity(0.08)).frame(height: 96)
                    .accessibilityLabel("Loading shared items")
            }
            if let err = vm.galleryError {
                HStack {
                    errorText(err)
                    Button("Try again") { Task { if vm.galleryLoaded { await vm.loadMore() } else { await vm.loadGalleryFirstPage() } } }
                        .font(.inter(Theme.fontXS, weight: .semibold)).foregroundColor(Theme.gold).frame(minHeight: 44)
                }
            }
            if vm.galleryLoaded && vm.galleryItems.isEmpty && vm.galleryError == nil {
                Text(vm.filter.emptyCopy)
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.6))
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, Theme.spacingMD)
            }

            let media = vm.galleryItems.filter { $0.kind != "file" }
            let files = vm.galleryItems.filter { $0.kind == "file" }
            if !media.isEmpty {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(media) { item in galleryTile(item) }
                }
            }
            if !files.isEmpty {
                VStack(spacing: Theme.spacingXS) {
                    ForEach(files) { item in fileRow(item) }
                }
            }
            if vm.galleryHasMore {
                Button { Task { await vm.loadMore() } } label: {
                    Group {
                        if vm.galleryLoading { ProgressView().tint(Theme.gold) }
                        else { Text("Load more").font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.gold) }
                    }
                    .frame(minWidth: 120, minHeight: 44)
                    .overlay(Capsule().stroke(Theme.borderGoldDim, lineWidth: 1))
                }
                .disabled(vm.galleryLoading)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Load more shared items")
            }
        }
    }

    // ── Gallery cells ────────────────────────────────────────────────────────
    private func tileLabel(_ item: FSGalleryItem) -> String {
        let noun = item.kind == "video" ? "Video" : item.kind == "gif" ? "GIF" : "Photo"
        return "\(noun) from \(item.from_user.isEmpty ? "a member" : item.from_user)"
    }

    @ViewBuilder
    private func galleryTile(_ item: FSGalleryItem) -> some View {
        let previewString = (item.kind == "gif" ? item.meta?.previewUrl : nil) ?? item.url
        Button {
            guard let urlString = item.url, let url = URL(string: urlString) else { return }
            if item.kind == "video" { UIApplication.shared.open(url) } else { viewerItem = item }
        } label: {
            Color.white.opacity(0.06)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if item.kind == "video" {
                        Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundColor(Theme.gold)
                    } else if let s = previewString, let url = URL(string: s) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) }
                        }
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if item.kind == "gif" {
                        Text("GIF").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.black.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
        }
        .buttonStyle(.plain)
        .disabled(item.url == nil)
        .accessibilityLabel(item.url == nil ? "\(tileLabel(item)), unavailable" : tileLabel(item))
    }

    @ViewBuilder
    private func fileRow(_ item: FSGalleryItem) -> some View {
        let name = item.meta?.filename ?? "File"
        let content = HStack(spacing: Theme.spacingSM) {
            Image(systemName: "doc.fill").foregroundColor(Theme.gold)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment).lineLimit(1)
                Text(item.from_user).font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "arrow.down.circle").foregroundColor(Theme.gold)
        }
        .padding(Theme.spacingSM)
        .frame(minHeight: 48)
        .background(Theme.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        if let s = item.url, let url = URL(string: s) {
            Link(destination: url) { content }.accessibilityLabel("File \(name) from \(item.from_user), download")
        } else {
            content.accessibilityLabel("File \(name), unavailable")
        }
    }

    private var undoToast: some View {
        HStack {
            Text("Group photo removed.").font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
            Spacer()
            Button("Undo") { Task { await vm.undoRemove() } }
                .font(.inter(Theme.fontSM, weight: .bold)).foregroundColor(Theme.gold).frame(minHeight: 44)
        }
        .padding(.horizontal, Theme.spacingMD)
        .background(Theme.islandBg)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderGoldDim, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .padding(Theme.spacingMD)
        .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Group photo removed. Undo available for a few seconds.")
        .onAppear { UIAccessibility.post(notification: .announcement, argument: "Group photo removed. Undo available.") }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.inter(Theme.fontXXS, weight: .semibold)).tracking(3).textCase(.uppercase)
            .foregroundColor(Theme.gold.opacity(0.7))
            .accessibilityAddTraits(.isHeader)
    }

    private func errorText(_ text: String) -> some View {
        Text(text).font(.inter(Theme.fontXS)).foregroundColor(Theme.error)
            .accessibilityLabel(text)
    }

    private func saveName() {
        Task { if await vm.rename(to: draftName) { editingName = false } }
    }

    private func handlePicked(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                vm.photoError = "Could not read that photo. Please try again."
                photoPickerItem = nil
                return
            }
            let contentType = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
            await vm.uploadPhoto(data: data, contentType: contentType)
            photoPickerItem = nil
        }
    }
}

// FSGalleryItem is Identifiable already (fullScreenCover(item:)).

// ── Simple full-screen viewer for gallery images/GIFs ────────────────────────
private struct GroupGalleryViewer: View {
    let item: FSGalleryItem
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.92).ignoresSafeArea()
            if let s = item.url, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: .fit) }
                    else if phase.error != nil { Text("Image unavailable").foregroundColor(Theme.textSecondary) }
                    else { ProgressView().tint(Theme.gold) }
                }
                .padding(Theme.spacingLG)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.35))
                    .clipShape(Circle())
            }
            .padding(Theme.spacingMD)
            .accessibilityLabel("Close")
        }
        .onTapGesture { onDismiss() }
    }
}
