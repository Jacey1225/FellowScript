// GroupAnnouncementFormView.swift — create / edit form (task
// 20260929-group-announcements, design-notes.md "Create / edit form").
// Presented as a large sheet with a NavigationStack toolbar (Cancel / Post).
// Failures keep everything the user typed; a free-limit rejection shows the
// upgrade card inline instead of losing the draft. Editing never triggers the
// free-limit prompt (edits are not counted server-side).

import SwiftUI
import PhotosUI

enum AnnouncementLimits {
    static let titleMax = 255
    static let descriptionMax = 5000
    static let bannerMaxBytes = 15 * 1024 * 1024
    static let bannerTypes: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/heic"]
    static let bannerHelper = "JPG, PNG, or WebP, up to 15MB."
    static let bannerInvalid = "Choose a JPG, PNG, or WebP under 15MB."
    static let horizonDays = 365
}

struct GroupAnnouncementFormView: View {
    @ObservedObject var vm: GroupAnnouncementsViewModel
    let editing: FSGroupAnnouncement?
    var onDone: (FSGroupAnnouncement) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var text: String
    @State private var schedule: Bool
    @State private var when: Date
    @State private var banner: FSAnnouncementDraft.Banner = .unchanged
    @State private var bannerImage: UIImage?
    @State private var bannerBusy = false
    @State private var bannerError: String?
    @State private var pickerItem: PhotosPickerItem?
    @State private var saving = false
    @State private var error: String?
    @State private var gateHit = false
    @State private var dirty = false
    @State private var confirmDiscard = false

    init(vm: GroupAnnouncementsViewModel, editing: FSGroupAnnouncement?, onDone: @escaping (FSGroupAnnouncement) -> Void) {
        self.vm = vm
        self.editing = editing
        self.onDone = onDone
        _title = State(initialValue: editing?.title ?? "")
        _text = State(initialValue: editing?.description ?? "")
        let scheduled = editing.map { !$0.published } ?? false
        _schedule = State(initialValue: scheduled)
        _when = State(initialValue: editing.flatMap { FSAnnouncementDates.parse($0.publish_at) } ?? Date().addingTimeInterval(3600))
    }

    private var isEditing: Bool { editing != nil }
    /// A published announcement's publish time can't change.
    private var canReschedule: Bool { editing == nil || editing?.published == false }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { !trimmedTitle.isEmpty && !trimmedText.isEmpty && !saving && !bannerBusy }
    private var submitLabel: String { isEditing ? "Save" : (schedule ? "Schedule" : "Post") }

    var body: some View {
        NavigationStack {
            ZStack {
                    ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        bannerField
                        titleField
                        messageField
                        if canReschedule { publishField }
                        if !isEditing, !gateHit, let g = vm.gate, g.unlimited != true {
                            Text("Free plan: \(g.limit ?? 1) announcement per week. Used \(g.used ?? 0) of \(g.limit ?? 1).")
                                .font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.6))
                        }
                        if gateHit { AnnouncementLimitCard(gate: vm.gate, onDismiss: nil).padding(.horizontal, -Theme.spacingMD) }
                        if let error {
                            Text(error).font(.inter(Theme.fontXS)).foregroundColor(Theme.error)
                                .accessibilityLabel(error)
                        }
                    }
                    .padding(Theme.spacingMD)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .warmBloomBackground()
            .navigationTitle(isEditing ? "Edit announcement" : "New announcement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if dirty { confirmDiscard = true } else { dismiss() } }
                        .foregroundColor(Theme.gold)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await submit() } } label: {
                        if saving { ProgressView().tint(Theme.gold) } else { Text(submitLabel).fontWeight(.bold) }
                    }
                    .foregroundColor(Theme.gold)
                    .disabled(!canSubmit)
                }
            }
            .confirmationDialog("Discard this announcement?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .interactiveDismissDisabled(dirty)
        .onChange(of: pickerItem) { _, item in handlePicked(item) }
    }

    // ── Fields ───────────────────────────────────────────────────────────────
    private func label(_ text: String) -> some View {
        Text(text)
            .font(.inter(Theme.fontXXS, weight: .semibold)).tracking(3).textCase(.uppercase)
            .foregroundColor(Theme.gold.opacity(0.7))
            .accessibilityAddTraits(.isHeader)
    }

    private var currentBannerURL: URL? {
        if banner == .unchanged, let s = editing?.banner_url { return URL(string: s) }
        return nil
    }
    private var hasBanner: Bool {
        if bannerImage != nil { return true }
        if banner == .unchanged, editing?.banner_url != nil { return true }
        return false
    }

    private var bannerField: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            label("Banner photo (optional)")
            if hasBanner {
                Color.white.opacity(0.06)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if let img = bannerImage {
                            Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                        } else if let url = currentBannerURL {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) }
                            }
                        }
                    }
                    .overlay { if bannerBusy { ProgressView().tint(Theme.gold) } }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .opacity(bannerBusy ? 0.5 : 1)
                    .accessibilityHidden(true)
                HStack {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Text("Replace").font(.inter(Theme.fontSM)).foregroundColor(Theme.gold).frame(minHeight: 44)
                    }
                    .disabled(bannerBusy)
                    Button("Remove") { banner = .removed; bannerImage = nil; dirty = true }
                        .font(.inter(Theme.fontSM)).foregroundColor(Theme.error).frame(minHeight: 44)
                        .disabled(bannerBusy)
                }
            } else {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    VStack(spacing: 4) {
                        if bannerBusy { ProgressView().tint(Theme.gold) }
                        else { Text("Add banner photo").font(.inter(Theme.fontSM)).foregroundColor(Theme.gold) }
                        Text(AnnouncementLimits.bannerHelper).font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.borderGold, style: StrokeStyle(lineWidth: 1, dash: [6])))
                }
                .disabled(bannerBusy)
                .accessibilityLabel("Add banner photo")
            }
            if let bannerError { Text(bannerError).font(.inter(Theme.fontXS)).foregroundColor(Theme.error) }
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            label("Title")
            TextField("Title", text: $title)
                .font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                .padding(.horizontal, Theme.spacingSM).frame(minHeight: 44)
                .background(Theme.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderGoldDim, lineWidth: 1))
                .disabled(saving)
                .onChange(of: title) { _, v in
                    dirty = true
                    if v.count > AnnouncementLimits.titleMax { title = String(v.prefix(AnnouncementLimits.titleMax)) }
                }
                .accessibilityLabel("Title")
            if title.count >= AnnouncementLimits.titleMax - 20 {
                Text("\(title.count)/\(AnnouncementLimits.titleMax)").font(.inter(Theme.fontXXS)).foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if trimmedTitle.isEmpty {
                Text("Give it a title.").font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
            }
        }
    }

    private var messageField: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            label("Message")
            TextEditor(text: $text)
                .font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                .scrollContentBackground(.hidden)
                .padding(Theme.spacingXS)
                .frame(minHeight: 120)
                .background(Theme.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderGoldDim, lineWidth: 1))
                .disabled(saving)
                .onChange(of: text) { _, v in
                    dirty = true
                    if v.count > AnnouncementLimits.descriptionMax { text = String(v.prefix(AnnouncementLimits.descriptionMax)) }
                }
                .accessibilityLabel("Message")
            if text.count >= AnnouncementLimits.descriptionMax - 200 {
                Text("\(text.count)/\(AnnouncementLimits.descriptionMax)").font(.inter(Theme.fontXXS)).foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if trimmedText.isEmpty {
                Text("Write a message for the group.").font(.inter(Theme.fontXS)).foregroundColor(Theme.textSecondary)
            }
        }
    }

    private var publishField: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            label("Publish")
            HStack(spacing: Theme.spacingSM) {
                publishChip("Now", selected: !schedule, value: false)
                publishChip("Schedule", selected: schedule, value: true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Publish")
            .disabled(saving)
            if schedule {
                DatePicker("Publish date and time", selection: Binding(get: { when }, set: { when = $0; dirty = true }),
                           in: Date()...Date().addingTimeInterval(TimeInterval(AnnouncementLimits.horizonDays * 86_400)))
                    .datePickerStyle(.compact)
                    .font(.inter(Theme.fontSM))
                    .tint(Theme.gold)
                    .disabled(saving)
                Text("Shown in your time zone, \(TimeZone.current.identifier).")
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.6))
            }
        }
    }

    private func publishChip(_ title: String, selected: Bool, value: Bool) -> some View {
        Button { schedule = value; dirty = true } label: {
            Text(title)
                .font(.inter(Theme.fontXS, weight: .semibold))
                .foregroundColor(selected ? Theme.gold : Theme.parchment.opacity(0.8))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(selected ? Theme.gold.opacity(0.15) : Color.clear)
                .overlay(Capsule().stroke(selected ? Theme.borderGold : Theme.borderGoldDim, lineWidth: 1))
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // ── Actions ──────────────────────────────────────────────────────────────
    private func handlePicked(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            defer { pickerItem = nil }
            bannerError = nil
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                bannerError = "Could not read that photo. Please try again."
                return
            }
            let contentType = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
            guard data.count <= AnnouncementLimits.bannerMaxBytes, AnnouncementLimits.bannerTypes.contains(contentType) else {
                bannerError = AnnouncementLimits.bannerInvalid
                return
            }
            bannerBusy = true
            defer { bannerBusy = false }
            do {
                let key = try await vm.uploadBanner(data: data, contentType: contentType)
                banner = .uploaded(key)
                bannerImage = UIImage(data: data)
                dirty = true
            } catch {
                bannerError = (error as? LocalizedError)?.errorDescription ?? "Upload failed. Please try again."
            }
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        saving = true
        error = nil
        defer { saving = false }
        var draft = FSAnnouncementDraft(title: trimmedTitle, description: trimmedText, banner: banner)
        draft.includePublishAt = canReschedule
        if schedule { draft.publishAt = when }
        else if isEditing { draft.publishAt = Date() }   // update rejects a null publish_at
        do {
            let saved = try await vm.save(draft, editing: editing)
            onDone(saved)
        } catch AppError.limitReached {
            gateHit = true
        } catch {
            if vm.removedFromGroup { return }
            let msg = (error as? LocalizedError)?.errorDescription
            if case AppError.networkError = error, let msg, !msg.isEmpty, msg != "Server error 500" {
                self.error = msg.count < 140 ? msg : "That didn't save. Please try again."
            } else {
                self.error = "That didn't save. Please try again."
            }
        }
    }
}
