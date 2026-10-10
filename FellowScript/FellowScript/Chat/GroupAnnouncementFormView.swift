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
    // Canonical banner geometry: every surface derives its box from bannerAspect;
    // the crop is baked into the uploaded JPEG at bannerOutputWidth.
    static let bannerAspect: CGFloat = 3
    static let bannerOutputWidth: CGFloat = 1536
    static let bannerJpegQuality: CGFloat = 0.85
    static let cropZoomMax: CGFloat = 4
}

struct GroupAnnouncementFormView: View {
    @ObservedObject var vm: GroupAnnouncementsViewModel
    let editing: FSGroupAnnouncement?
    var onDone: (FSGroupAnnouncement) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.fsCapabilities) private var capabilities
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: Field?
    private enum Field { case title, message }

    @State private var title: String
    @State private var text: String
    @State private var schedule: Bool
    @State private var when: Date
    @State private var banner: FSAnnouncementDraft.Banner = .unchanged
    @State private var titleColor: String?
    @State private var titleFont: String?
    @State private var bgTheme: String?
    @State private var extras: AnnouncementExtrasDraft
    @State private var extrasBusy = false
    @State private var showStock = false
    @State private var pendingStock: UIImage?
    @State private var showTheme = false
    @State private var bannerImage: UIImage?
    @State private var bannerBusy = false
    @State private var bannerError: String?
    @State private var pickerItem: PhotosPickerItem?
    @State private var cropImage: UIImage?
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
        _titleColor = State(initialValue: AnnouncementTitleColor.normalized(editing?.title_color))
        _titleFont = State(initialValue: editing?.title_font)
        _bgTheme = State(initialValue: editing?.bg_theme)
        _extras = State(initialValue: AnnouncementExtrasDraft(from: editing))
        let scheduled = editing.map { !$0.published } ?? false
        _schedule = State(initialValue: scheduled)
        _when = State(initialValue: editing.flatMap { FSAnnouncementDates.parse($0.publish_at) } ?? Date().addingTimeInterval(3600))
    }

    private var isEditing: Bool { editing != nil }
    /// A published announcement's publish time can't change.
    private var canReschedule: Bool { editing == nil || editing?.published == false }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { !trimmedTitle.isEmpty && !trimmedText.isEmpty && !saving && !bannerBusy && !extrasBusy && extrasError == nil }
    /// Server-gated controls: hidden (and never sent) while their flag is off.
    private var fontsOn: Bool { capabilities.isEnabled(AnnouncementTitleFont.flagName) }
    private var themesOn: Bool { capabilities.isEnabled(AnnouncementBgTheme.flagName) }
    private var linksOn: Bool { capabilities.isEnabled(AnnouncementExtrasFlag.links) }
    private var galleryOn: Bool { capabilities.isEnabled(AnnouncementExtrasFlag.gallery) }
    private var paymentsOn: Bool { capabilities.isEnabled(AnnouncementExtrasFlag.payments) }
    private var rsvpOn: Bool { capabilities.isEnabled(AnnouncementExtrasFlag.rsvp) }
    private var extrasOn: Bool { linksOn || galleryOn || paymentsOn || rsvpOn }
    private var extrasError: String? { extrasOn ? extras.blockingError(links: linksOn, payments: paymentsOn) : nil }
    private var submitLabel: String { isEditing ? "Save" : (schedule ? "Schedule" : "Post") }

    var body: some View {
        NavigationStack {
            ZStack {
                    ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        bannerField
                        if themesOn { themeStrip }
                        titleField
                        titleColorField
                        messageField
                        if canReschedule { publishField }
                        if extrasOn {
                            AnnouncementExtrasSection(
                                extras: $extras, linksOn: linksOn, galleryOn: galleryOn, paymentsOn: paymentsOn, rsvpOn: rsvpOn,
                                saving: saving, busy: $extrasBusy,
                                upload: { data in try await vm.uploadBanner(data: data, contentType: "image/jpeg") },
                                onChange: { dirty = true })
                        }
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
                        if saving { ProgressView().tint(Theme.gold) } else { Text(bannerBusy || extrasBusy ? "Uploading…" : submitLabel).fontWeight(.bold) }
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
        .sheet(isPresented: $showStock, onDismiss: {
            // Open the crop step only after the sheet is gone (two covers can't overlap).
            if let img = pendingStock { pendingStock = nil; bannerError = nil; cropImage = img }
        }) {
            AnnouncementStockPicker(photos: AnnouncementStockCatalog.shared) { pendingStock = $0 }
        }
        .sheet(isPresented: $showTheme) {
            AnnouncementBgThemeSheet(key: $bgTheme) { dirty = true }
        }
        .fullScreenCover(isPresented: Binding(get: { cropImage != nil }, set: { if !$0 { cropImage = nil } })) {
            if let cropImage {
                AnnouncementBannerCropView(image: cropImage, onCancel: { self.cropImage = nil }) { jpeg in
                    // Flip busy synchronously, before the cover dismisses, so Post/Save
                    // is never enabled in the gap before the upload Task starts.
                    self.bannerBusy = true
                    self.cropImage = nil
                    Task { await uploadCropped(jpeg) }
                }
            }
        }
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
            AnnouncementBannerTile(
                item: previewItem, previewImage: bannerImage, hasBanner: hasBanner, busy: bannerBusy,
                showStock: !AnnouncementStockCatalog.shared.isEmpty,
                pickerItem: $pickerItem,
                onStock: { showStock = true },
                onRemove: { banner = .removed; bannerImage = nil; dirty = true }
            )
            if fontsOn {
                AnnouncementTitleFontRow(key: $titleFont, sample: trimmedTitle) { dirty = true }
                    .disabled(saving)
            }
            if hasBanner {
                Button { Task { await adjustCrop() } } label: {
                    Text("Adjust crop").font(.inter(Theme.fontSM)).foregroundColor(Theme.gold).frame(minHeight: 44)
                }
                .disabled(bannerBusy)
            }
            if bannerError != nil || hasBanner {
                Text(bannerError ?? AnnouncementLimits.bannerHelper)
                    .font(.inter(Theme.fontXS)).foregroundColor(bannerError == nil ? Theme.parchment.opacity(0.6) : Theme.error)
            }
        }
    }

    /// Part D: live strip showing the theme under the banner, with the palette
    /// button at its bottom left.
    private var themeStrip: some View {
        let theme = AnnouncementBgTheme.resolve(bgTheme)
        return ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 2) {
                Text(trimmedTitle.isEmpty ? "Your title" : trimmedTitle)
                    .font(AnnouncementTitleFont.resolve(titleFont).font(Theme.fontSM))
                    .foregroundColor(AnnouncementTitleColor.surfaceColor(titleColor, fallback: theme.readableText, surfaceHex: theme.surfaceHex))
                    .lineLimit(1)
                Text(trimmedText.isEmpty ? "Your message appears here." : trimmedText)
                    .font(.inter(Theme.fontXS)).foregroundColor(theme.readableText.opacity(0.85)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, Theme.spacingMD).padding(.top, Theme.spacingSM).padding(.bottom, 52)
            Button { showTheme = true } label: {
                Image(systemName: "paintpalette")
                    .font(.system(size: 17)).foregroundColor(Theme.parchment)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                    .contentShape(Circle())
            }
            .padding(Theme.spacingSM)
            .accessibilityLabel("Background theme")
            .accessibilityValue(theme.accessibilityName)
        }
        .background {
            if theme == .none { Color.white.opacity(0.04) } else { theme.fill }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Color.white.opacity(0.28), lineWidth: 1))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: bgTheme)
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            label("Title")
            TextField("Title", text: $title, prompt: Text("Title").foregroundColor(Theme.parchment.opacity(0.65)))
                .font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                .padding(.horizontal, Theme.spacingSM).frame(minHeight: 44)
                .focused($focusedField, equals: .title)
                .announcementTranslucentField(focused: focusedField == .title)
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

    private var titleColorField: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            label("Title color")
            AnnouncementTitleColorPicker(hex: $titleColor) { dirty = true }
                .disabled(saving)
        }
    }

    /// Live preview source: the real card face with the draft title and color.
    private var previewItem: FSGroupAnnouncement {
        FSGroupAnnouncement(id: "preview", group_id: editing?.group_id ?? "", creator_id: nil, creator_username: nil,
                            title: trimmedTitle.isEmpty ? "Your title" : trimmedTitle, description: "",
                            banner_url: (bannerImage == nil && banner == .unchanged) ? editing?.banner_url : nil,
                            publish_at: "", created_at: "", updated_at: "", published: true, can_edit: false,
                            title_color: titleColor, title_font: fontsOn ? titleFont : editing?.title_font,
                            bg_theme: themeValue)
    }

    private var themeValue: String? { themesOn ? bgTheme : editing?.bg_theme }

    private var messageField: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            label("Message")
            TextEditor(text: $text)
                .font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                .scrollContentBackground(.hidden)
                .padding(Theme.spacingXS)
                .frame(minHeight: 120)
                .focused($focusedField, equals: .message)
                .announcementTranslucentField(focused: focusedField == .message)
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
    /// Picking a photo opens the crop step; nothing uploads until the crop is confirmed.
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
            do { cropImage = try AnnouncementCropMath.decode(data: data) }
            catch { bannerError = (error as? LocalizedError)?.errorDescription ?? "Could not read that photo. Please try again." }
        }
    }

    /// Re-crop the current banner: a photo cropped this session is reused; a
    /// saved remote banner is downloaded first. Failure never uploads anything.
    private func adjustCrop() async {
        bannerError = nil
        if let img = bannerImage { cropImage = img; return }
        guard let url = currentBannerURL else { return }
        bannerBusy = true
        defer { bannerBusy = false }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
                throw AnnouncementCropError.decode
            }
            cropImage = try AnnouncementCropMath.decode(data: data)
        } catch {
            bannerError = "Can't re-crop this banner. Choose Replace photo instead."
        }
    }

    private func uploadCropped(_ jpeg: Data) async {
        bannerError = nil
        bannerBusy = true
        defer { bannerBusy = false }
        do {
            let key = try await vm.uploadBanner(data: jpeg, contentType: "image/jpeg")
            banner = .uploaded(key)
            bannerImage = UIImage(data: jpeg)
            dirty = true
        } catch {
            bannerError = (error as? LocalizedError)?.errorDescription ?? "Upload failed. Please try again."
        }
    }

    /// Create: send only a non-default color. Edit: send only what changed
    /// (explicit null resets a previously saved color to the default).
    private var titleColorChange: FSAnnouncementDraft.TitleColor {
        let original = AnnouncementTitleColor.normalized(editing?.title_color)
        let chosen = AnnouncementTitleColor.normalized(titleColor)
        if chosen == original { return .unchanged }
        if let chosen { return .set(chosen) }
        return .reset
    }

    /// Same rule as the title color: send only what changed; explicit null resets.
    private func keyChange(original: String?, chosen: String?) -> FSAnnouncementDraft.KeyChange {
        if chosen == original { return .unchanged }
        if let chosen { return .set(chosen) }
        return .reset
    }

    private func submit() async {
        guard canSubmit else { return }
        saving = true
        error = nil
        defer { saving = false }
        var draft = FSAnnouncementDraft(title: trimmedTitle, description: trimmedText, banner: banner)
        draft.includePublishAt = canReschedule
        draft.titleColor = titleColorChange
        // Style keys are only touched while their server flag is on (else 422).
        if fontsOn {
            draft.titleFont = keyChange(original: AnnouncementTitleFont.resolve(editing?.title_font).storedKey,
                                        chosen: AnnouncementTitleFont.resolve(titleFont).storedKey)
        }
        if themesOn {
            draft.bgTheme = keyChange(original: AnnouncementBgTheme.resolve(editing?.bg_theme).storedKey,
                                      chosen: AnnouncementBgTheme.resolve(bgTheme).storedKey)
        }
        if extrasOn {
            extras.apply(to: &draft, original: editing, links: linksOn, gallery: galleryOn, payments: paymentsOn, rsvp: rsvpOn)
        }
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
