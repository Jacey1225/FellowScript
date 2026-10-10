// AnnouncementExtrasForm.swift — the collapsed "Add extras" section at the very
// bottom of the announcement form (task 20261009-announcements-advanced, part E,
// design-notes.md item 6). Each row renders only while its server capability is
// on; with all four off the section is absent and the form is unchanged.

import SwiftUI
import PhotosUI

/// Disclosure row: 44pt header with chevron, optional summary, content below.
/// Expands in 200ms ease-out, instantly under Reduce Motion.
private struct ExtrasDisclosure<Content: View>: View {
    let title: String
    var summary: String? = nil
    var warning: String? = nil
    var prominent = false
    @Binding var isOpen: Bool
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { isOpen.toggle() }
            } label: {
                HStack(spacing: Theme.spacingSM) {
                    Text(title)
                        .font(.inter(prominent ? Theme.fontSM : Theme.fontSM, weight: .semibold))
                        .foregroundColor(Theme.parchment)
                    if let summary {
                        Text(summary)
                            .font(.inter(Theme.fontXS, weight: .semibold)).foregroundColor(Theme.bgPage)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.gold))
                    }
                    if let warning {
                        Text(warning).font(.inter(Theme.fontXS)).foregroundColor(Theme.error)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.gold)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue([summary.map { "\($0) set" }, warning, isOpen ? "expanded" : "collapsed"].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint(isOpen ? "Collapses" : "Expands")
            .accessibilityAddTraits(.isButton)
            if isOpen { content() }
        }
    }
}

struct AnnouncementExtrasSection: View {
    @Binding var extras: AnnouncementExtrasDraft
    let linksOn: Bool
    let galleryOn: Bool
    let paymentsOn: Bool
    let rsvpOn: Bool
    var locationOn: Bool = false
    let saving: Bool
    @Binding var busy: Bool
    var upload: (Data) async throws -> String
    var onChange: () -> Void

    @State private var open = false
    @State private var openLinks = false
    @State private var openGallery = false
    @State private var openPayments = false
    @State private var openSpots = false
    @State private var openLocation = false
    @State private var picks: [PhotosPickerItem] = []
    @State private var galleryError: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var total: Int { extras.count(links: linksOn, gallery: galleryOn, payments: paymentsOn, rsvp: rsvpOn, location: locationOn) }
    private var blocking: String? { extras.blockingError(links: linksOn, payments: paymentsOn, location: locationOn) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1).accessibilityHidden(true)
            ExtrasDisclosure(title: "Add extras (optional)", summary: total > 0 ? "\(total)" : nil,
                             warning: open ? nil : blocking, prominent: true, isOpen: $open) {
                VStack(alignment: .leading, spacing: Theme.spacingXS) {
                    if linksOn { linksRow }
                    if galleryOn { galleryRow }
                    if paymentsOn { paymentsRow }
                    if rsvpOn { spotsRow }
                    if locationOn { locationRow }
                    if let blocking {
                        Text(blocking).font(.inter(Theme.fontXS)).foregroundColor(Theme.error)
                    }
                }
                .padding(.leading, Theme.spacingSM)
            }
        }
        .disabled(saving)
    }

    // ── Links ────────────────────────────────────────────────────────────────
    private var linksRow: some View {
        ExtrasDisclosure(title: "Links", summary: extras.cleanedLinks.isEmpty ? nil : "\(extras.cleanedLinks.count)", isOpen: $openLinks) {
            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                ForEach($extras.links) { $row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Theme.spacingXS) {
                            VStack(spacing: Theme.spacingXS) {
                                TextField("Link", text: $row.url, prompt: Text("example.com/page").foregroundColor(Theme.parchment.opacity(0.65)))
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                    .font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                                    .padding(.horizontal, Theme.spacingSM).frame(minHeight: 44)
                                    .announcementTranslucentField()
                                    .accessibilityLabel("Link address")
                                TextField("Label", text: $row.label, prompt: Text("Label (optional)").foregroundColor(Theme.parchment.opacity(0.65)))
                                    .font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                                    .padding(.horizontal, Theme.spacingSM).frame(minHeight: 44)
                                    .announcementTranslucentField()
                                    .onChange(of: row.label) { _, v in
                                        if v.count > AnnouncementExtrasLimits.maxLabelLength { row.label = String(v.prefix(AnnouncementExtrasLimits.maxLabelLength)) }
                                    }
                                    .accessibilityLabel("Link label")
                            }
                            Button {
                                extras.links.removeAll { $0.id == row.id }; onChange()
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundColor(Theme.parchment.opacity(0.7))
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                            }
                            .accessibilityLabel("Remove link")
                        }
                        if let e = extras.linkError(row) {
                            Text(e).font(.inter(Theme.fontXS)).foregroundColor(Theme.error)
                        }
                    }
                }
                if extras.links.count < AnnouncementExtrasLimits.maxLinks {
                    Button { extras.links.append(.init()); onChange() } label: {
                        Label("Add link", systemImage: "plus")
                            .font(.inter(Theme.fontSM)).foregroundColor(Theme.gold).frame(minHeight: 44)
                    }
                }
                Text("Up to \(AnnouncementExtrasLimits.maxLinks) web links. They open in Safari.")
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.6))
            }
        }
        .onChange(of: extras.links) { _, _ in onChange() }
    }

    // ── Gallery ──────────────────────────────────────────────────────────────
    private var galleryRow: some View {
        let n = extras.gallery.count
        return ExtrasDisclosure(title: "Photo gallery", summary: n > 0 ? "\(n) of \(AnnouncementExtrasLimits.maxGallery)" : nil, isOpen: $openGallery) {
            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                if n > 0 {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 140 : 96), spacing: Theme.spacingSM)], spacing: Theme.spacingSM) {
                        ForEach(Array(extras.gallery.enumerated()), id: \.element.id) { idx, row in
                            thumb(row, index: idx, total: n)
                        }
                    }
                }
                if n < AnnouncementExtrasLimits.maxGallery {
                    PhotosPicker(selection: $picks, maxSelectionCount: max(1, AnnouncementExtrasLimits.maxGallery - n), matching: .images) {
                        Label(busy ? "Uploading…" : "Add photos", systemImage: "photo.on.rectangle.angled")
                            .font(.inter(Theme.fontSM)).foregroundColor(Theme.gold).frame(minHeight: 44)
                    }
                    .disabled(busy)
                    .onChange(of: picks) { _, items in if !items.isEmpty { Task { await addPicked(items) } } }
                }
                if let galleryError {
                    Text(galleryError).font(.inter(Theme.fontXS)).foregroundColor(Theme.error)
                }
                Text("Up to \(AnnouncementExtrasLimits.maxGallery) photos, shown to the group in order.")
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.6))
            }
        }
    }

    private func thumb(_ row: AnnouncementExtrasDraft.GalleryRow, index: Int, total: Int) -> some View {
        Color.white.opacity(0.06)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let img = row.preview {
                    Image(uiImage: img).resizable().scaledToFill()
                } else if let url = row.remoteURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button {
                    extras.gallery.removeAll { $0.id == row.id }; onChange()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold)).foregroundColor(Theme.parchment)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Remove photo \(index + 1) of \(total)")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Gallery photo \(index + 1) of \(total)")
    }

    private func addPicked(_ items: [PhotosPickerItem]) async {
        picks = []
        galleryError = nil
        busy = true
        defer { busy = false }
        var failed = 0
        for item in items {
            guard extras.gallery.count < AnnouncementExtrasLimits.maxGallery else { break }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  data.count <= AnnouncementLimits.bannerMaxBytes,
                  let jpeg = await AnnouncementGalleryProcessor.jpeg(from: data) else { failed += 1; continue }
            do {
                let key = try await upload(jpeg)
                extras.gallery.append(.init(key: key, remoteURL: nil, preview: UIImage(data: jpeg)))
                onChange()
            } catch {
                failed += 1
            }
        }
        if failed > 0 {
            galleryError = failed == 1 ? "One photo couldn't be added. Try again." : "\(failed) photos couldn't be added. Try again."
        }
    }

    // ── Event payments ───────────────────────────────────────────────────────
    private var paymentsRow: some View {
        ExtrasDisclosure(title: "Event payments", summary: extras.isEvent ? "On" : nil, isOpen: $openPayments) {
            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                Toggle(isOn: $extras.isEvent) {
                    Text("This is an event").font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                }
                .tint(Theme.gold).frame(minHeight: 44)
                .onChange(of: extras.isEvent) { _, _ in onChange() }
                if extras.isEvent {
                    ForEach(AnnouncementPaymentProvider.allCases) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).font(.inter(Theme.fontXS, weight: .semibold)).foregroundColor(Theme.parchment.opacity(0.8))
                            TextField(p.title, text: Binding(get: { extras.handles[p.rawValue] ?? "" },
                                                             set: { extras.handles[p.rawValue] = $0; onChange() }),
                                      prompt: Text(p.placeholder).foregroundColor(Theme.parchment.opacity(0.65)))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                                .padding(.horizontal, Theme.spacingSM).frame(minHeight: 44)
                                .announcementTranslucentField()
                                .accessibilityLabel("\(p.title) handle")
                            if let e = extras.handleError(p) {
                                Text(e).font(.inter(Theme.fontXS)).foregroundColor(Theme.error)
                            }
                        }
                    }
                }
                Text(AnnouncementExtrasLimits.paymentDisclaimer)
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // ── Location ─────────────────────────────────────────────────────────────
    private var locationRow: some View {
        ExtrasDisclosure(title: "Location", summary: extras.cleanedLocation.isEmpty ? nil : "1", isOpen: $openLocation) {
            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                TextField("Location", text: $extras.location, prompt: Text("Where is it? (optional)").foregroundColor(Theme.parchment.opacity(0.65)))
                    .font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                    .padding(.horizontal, Theme.spacingSM).frame(minHeight: 44)
                    .announcementTranslucentField()
                    .onChange(of: extras.location) { _, v in
                        if v.count > AnnouncementExtrasLimits.maxLocationLength { extras.location = String(v.prefix(AnnouncementExtrasLimits.maxLocationLength)) }
                        onChange()
                    }
                    .accessibilityLabel("Location")
                    .accessibilityHint("Optional. Up to \(AnnouncementExtrasLimits.maxLocationLength) characters.")
                Text("A place name or address. Tapping it opens Apple Maps.")
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.6))
            }
        }
    }

    // ── Spots (RSVP) ─────────────────────────────────────────────────────────
    private var spotsRow: some View {
        ExtrasDisclosure(title: "Spots", summary: extras.rsvpOn ? "\(extras.capacity)" : nil, isOpen: $openSpots) {
            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                Toggle(isOn: $extras.rsvpOn) {
                    Text("Let members RSVP").font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                }
                .tint(Theme.gold).frame(minHeight: 44)
                .onChange(of: extras.rsvpOn) { _, _ in onChange() }
                if extras.rsvpOn {
                    Stepper(value: $extras.capacity, in: AnnouncementExtrasLimits.capacityRange) {
                        Text("\(extras.capacity) spots").font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment)
                    }
                    .frame(minHeight: 44)
                    .onChange(of: extras.capacity) { _, _ in onChange() }
                    .accessibilityLabel("Number of spots")
                    .accessibilityValue("\(extras.capacity)")
                }
                Text("Members RSVP to this announcement. It doesn't add anyone to the group. Turning this off clears the RSVPs.")
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
