// AnnouncementExtrasDetail.swift — part E attachments in the announcement
// detail view (task 20261009-announcements-advanced). Every block is hidden
// when its data is empty, so an announcement with no extras (or a server with
// the flags off, which omits the keys) renders exactly as before.
//
// Safety: links open only in SFSafariViewController (never a web view of our
// own) and always show their host; payment handles are plain text with a
// "paid outside the app" disclaimer; RSVP is a count, never group membership.

import SwiftUI

struct AnnouncementExtrasDetail: View {
    let item: FSGroupAnnouncement
    let textColor: Color
    /// Join (true) / leave (false). Nil = read-only (count only).
    var onRSVP: ((Bool) async throws -> FSGroupAnnouncement)?
    /// Poll voting. Nil = read-only (live results only).
    var pollActions: AnnouncementPollActions? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var safari: ExploreDestination?
    @State private var viewerIndex: Int?
    @State private var override: (count: Int, joined: Bool)?
    @State private var rsvpBusy = false
    @State private var rsvpError: String?
    @State private var pollOverride: FSAnnouncementPoll?
    @State private var pollBusy = false
    @State private var pollError: String?

    private var gallery: [FSAnnouncementGalleryImage] { (item.gallery ?? []).filter { $0.url.flatMap(URL.init(string:)) != nil } }
    private var links: [(link: FSAnnouncementLink, url: URL)] {
        (item.links ?? []).compactMap { l in AnnouncementLinkSafety.parse(l.url).map { (l, $0) } }
    }
    private var handles: [(provider: AnnouncementPaymentProvider, handle: String)] {
        guard item.is_event == true else { return [] }
        return (item.payment_handles ?? []).compactMap { h in
            AnnouncementPaymentProvider(rawValue: h.provider).map { ($0, h.handle) }
        }
    }

    private var locationText: String? {
        let t = (item.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingMD) {
            if !gallery.isEmpty { galleryBlock }
            if !links.isEmpty { linksBlock }
            if !handles.isEmpty { paymentsBlock }
            if let place = locationText { locationBlock(place) }
            if let poll = pollOverride ?? item.poll { pollBlock(poll) }
            if let cap = item.capacity { rsvpBlock(capacity: cap) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .exploreSafariSheet($safari)
        .fullScreenCover(isPresented: Binding(get: { viewerIndex != nil }, set: { if !$0 { viewerIndex = nil } })) {
            AnnouncementGalleryViewer(images: gallery, start: viewerIndex ?? 0) { viewerIndex = nil }
        }
        .onChange(of: item) { _, _ in override = nil; pollOverride = nil }
    }

    private func heading(_ t: String) -> some View {
        Text(t)
            .font(.inter(Theme.fontXXS, weight: .semibold)).tracking(3).textCase(.uppercase)
            .foregroundColor(textColor.opacity(0.75))
            .accessibilityAddTraits(.isHeader)
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c()
            .padding(Theme.spacingSM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Color.white.opacity(0.28), lineWidth: 1))
    }

    // ── Gallery ──────────────────────────────────────────────────────────────
    private var galleryBlock: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            heading("Photos")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.spacingSM) {
                    ForEach(Array(gallery.enumerated()), id: \.element.id) { idx, img in
                        Button { viewerIndex = idx } label: {
                            Color.white.opacity(0.06)
                                .frame(width: 168, height: 112)
                                .overlay {
                                    AsyncImage(url: img.url.flatMap(URL.init(string:))) { phase in
                                        if let image = phase.image { image.resizable().scaledToFill() }
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Color.white.opacity(0.28), lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Photo \(idx + 1) of \(gallery.count)")
                        .accessibilityHint("Opens the photo full screen")
                        .accessibilityAddTraits(.isImage)
                    }
                }
            }
        }
    }

    // ── Links ────────────────────────────────────────────────────────────────
    private var linksBlock: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            heading("Links")
            ForEach(Array(links.enumerated()), id: \.offset) { _, entry in
                let host = AnnouncementLinkSafety.displayHost(entry.url)
                let risky = AnnouncementLinkSafety.isLookalikeRisk(host: host)
                let title = (entry.link.label?.isEmpty == false) ? entry.link.label! : host
                Button { safari = ExploreDestination(url: entry.url) } label: {
                    card {
                        HStack(spacing: Theme.spacingSM) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title).font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(textColor)
                                    .multilineTextAlignment(.leading)
                                Text(host).font(.inter(Theme.fontXS)).foregroundColor(textColor.opacity(0.8))
                                if risky {
                                    Text("Unusual characters in this address. Check it before you continue.")
                                        .font(.inter(Theme.fontXS)).foregroundColor(Theme.gold)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right.square").foregroundColor(Theme.gold)
                        }
                        .frame(minHeight: 44)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), link to \(host)")
                .accessibilityValue(risky ? "Unusual characters in the address" : "")
                .accessibilityHint("Opens in Safari")
                .accessibilityAddTraits(.isLink)
            }
        }
    }

    // ── Location ─────────────────────────────────────────────────────────────
    private func locationBlock(_ place: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            heading("Location")
            Button {
                if let url = AnnouncementLocationMaps.url(for: place) { UIApplication.shared.open(url) }
            } label: {
                card {
                    HStack(spacing: Theme.spacingSM) {
                        Image(systemName: "mappin.and.ellipse").foregroundColor(Theme.gold)
                        Text(place).font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(textColor)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right.square").foregroundColor(Theme.gold)
                    }
                    .frame(minHeight: 44)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Location, \(place)")
            .accessibilityHint("Opens in Apple Maps")
            .accessibilityAddTraits(.isLink)
        }
    }

    // ── Payments (display only) ──────────────────────────────────────────────
    private var paymentsBlock: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            heading("Event payments")
            card {
                VStack(alignment: .leading, spacing: Theme.spacingSM) {
                    ForEach(handles, id: \.provider) { entry in
                        HStack(spacing: Theme.spacingSM) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.provider.title).font(.inter(Theme.fontXS)).foregroundColor(textColor.opacity(0.8))
                                Text(entry.handle).font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(textColor)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                            Button { UIPasteboard.general.string = entry.handle } label: {
                                Image(systemName: "doc.on.doc").foregroundColor(Theme.gold)
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                            }
                            .accessibilityLabel("Copy \(entry.provider.title) handle")
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text(AnnouncementExtrasLimits.paymentDisclaimer)
                        .font(.inter(Theme.fontXS)).foregroundColor(textColor.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // ── Poll ─────────────────────────────────────────────────────────────────
    private func pollBlock(_ poll: FSAnnouncementPoll) -> some View {
        let canVote = pollActions != nil && item.published && !poll.closed
        let mine = Set(poll.my_votes)
        let lead = poll.options.map(\.votes).max() ?? 0
        return VStack(alignment: .leading, spacing: Theme.spacingXS) {
            heading("Poll")
            card {
                VStack(alignment: .leading, spacing: Theme.spacingSM) {
                    Text(poll.question)
                        .font(.inter(Theme.fontSM, weight: .bold)).foregroundColor(textColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(poll.options) { o in
                        pollOptionRow(o, poll: poll, selected: mine.contains(o.id), canVote: canVote,
                                      leading: poll.closed && lead > 0 && o.votes == lead)
                    }
                    HStack(spacing: Theme.spacingSM) {
                        Text(pollFooter(poll))
                            .font(.inter(Theme.fontXS)).foregroundColor(textColor.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: Theme.spacingMD) {
                        if canVote, !mine.isEmpty {
                            pollTextButton("Clear my vote") { await pollRun { try await pollActions!.retract() } }
                        }
                        if item.can_edit, !poll.closed, let close = pollActions?.close {
                            pollTextButton("Close poll") { await pollRun { try await close() } }
                        }
                    }
                    if let pollError {
                        Text(pollError).font(.inter(Theme.fontXS)).foregroundColor(Theme.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Votes are anonymous. Only counts are shown.")
                        .font(.inter(Theme.fontXS)).foregroundColor(textColor.opacity(0.7))
                }
            }
        }
    }

    private func pollFooter(_ poll: FSAnnouncementPoll) -> String {
        var parts = ["\(poll.total_voters) \(poll.total_voters == 1 ? "person has" : "people have") voted"]
        if poll.multiple { parts.append("pick all that apply") }
        if poll.closed { parts.append("Poll closed") }
        else if let c = poll.closes_at, let d = FSAnnouncementDates.parse(c) {
            parts.append("closes \(d.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private func pollOptionRow(_ o: FSPollOption, poll: FSAnnouncementPoll, selected: Bool, canVote: Bool, leading: Bool) -> some View {
        Button { if canVote { Task { await pollToggle(o, poll: poll) } } } label: {
            ZStack(alignment: .leading) {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.gold.opacity(selected ? 0.30 : (leading ? 0.26 : 0.18)))
                        .frame(width: geo.size.width * CGFloat(max(0, min(100, o.percent))) / 100)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: o.percent)
                }
                HStack(spacing: Theme.spacingSM) {
                    Image(systemName: selected ? (poll.multiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                                               : (poll.multiple ? "square" : "circle"))
                        .foregroundColor(Theme.gold)
                    Text(o.label).font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(textColor)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text("\(o.percent)%").font(.inter(Theme.fontXS)).foregroundColor(textColor.opacity(0.85)).monospacedDigit()
                }
                .padding(.horizontal, Theme.spacingSM).padding(.vertical, 10)
            }
            .frame(minHeight: 44)
            .background(Theme.parchment.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(selected ? Theme.gold : Theme.parchment.opacity(0.12), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(pollBusy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(o.label), \(o.votes) \(o.votes == 1 ? "vote" : "votes"), \(o.percent) percent\(selected ? ", your choice" : "")")
        .accessibilityHint(canVote ? (selected && !poll.multiple ? "Your current choice" : "Double tap to vote") : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func pollTextButton(_ title: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Text(title).font(.inter(Theme.fontXS, weight: .semibold)).foregroundColor(Theme.gold)
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(pollBusy)
    }

    private func pollToggle(_ o: FSPollOption, poll: FSAnnouncementPoll) async {
        guard let actions = pollActions else { return }
        var next = Set(poll.my_votes)
        if poll.multiple {
            if next.contains(o.id) { next.remove(o.id) } else { next.insert(o.id) }
            if next.isEmpty { await pollRun { try await actions.retract() }; return }
        } else {
            if next.contains(o.id) { return }
            next = [o.id]
        }
        let ordered = poll.options.map(\.id).filter(next.contains)
        await pollRun { try await actions.vote(ordered) }
    }

    private func pollRun(_ call: () async throws -> FSGroupAnnouncement) async {
        guard !pollBusy else { return }
        pollBusy = true; pollError = nil
        defer { pollBusy = false }
        do {
            let updated = try await call()
            if let p = updated.poll { pollOverride = p }
        } catch {
            if case AppError.networkError(let m) = error, m.localizedCaseInsensitiveContains("closed") {
                pollError = "This poll just closed."
            } else if case AppError.networkError(let m) = error, !m.isEmpty, m.count < 100, !m.hasPrefix("Server error") {
                pollError = m
            } else {
                pollError = "Couldn't update the poll. Please try again."
            }
        }
    }

    // ── RSVP ─────────────────────────────────────────────────────────────────
    private func rsvpBlock(capacity: Int) -> some View {
        let count = override?.count ?? item.rsvp_count ?? 0
        let joined = override?.joined ?? item.rsvp_joined ?? false
        let full = count >= capacity && !joined
        let canAct = onRSVP != nil && item.published
        return VStack(alignment: .leading, spacing: Theme.spacingXS) {
            heading("RSVP")
            card {
                VStack(alignment: .leading, spacing: Theme.spacingSM) {
                    HStack(spacing: Theme.spacingSM) {
                        Text("\(count) of \(capacity) going")
                            .font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(textColor)
                            .accessibilityLabel("\(count) of \(capacity) going\(joined ? ", including you" : "")")
                        Spacer(minLength: 0)
                        if canAct {
                            Button { Task { await toggle(joined: joined, count: count) } } label: {
                                Text(joined ? "Cancel RSVP" : (full ? "Full" : "I'm going"))
                                    .font(.inter(Theme.fontSM, weight: .semibold))
                                    .foregroundColor(joined || full ? Theme.gold : Theme.bgPage)
                                    .padding(.horizontal, 14).frame(minHeight: 44)
                                    .background(Capsule().fill(joined || full ? Color.clear : Theme.gold))
                                    .overlay(Capsule().stroke(Theme.gold.opacity(joined || full ? 0.6 : 0), lineWidth: 1))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(rsvpBusy || full)
                            .accessibilityLabel(joined ? "Cancel your RSVP" : (full ? "Event is full" : "RSVP, I'm going"))
                        }
                    }
                    if let rsvpError {
                        Text(rsvpError).font(.inter(Theme.fontXS)).foregroundColor(Theme.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("RSVP only. It doesn't change your group membership.")
                        .font(.inter(Theme.fontXS)).foregroundColor(textColor.opacity(0.7))
                }
            }
        }
    }

    /// Optimistic: the count flips immediately and rolls back if the server refuses.
    private func toggle(joined: Bool, count: Int) async {
        guard let onRSVP, !rsvpBusy else { return }
        let before = override
        rsvpBusy = true
        rsvpError = nil
        override = (count: max(0, count + (joined ? -1 : 1)), joined: !joined)
        defer { rsvpBusy = false }
        do {
            let updated = try await onRSVP(!joined)
            override = (count: updated.rsvp_count ?? override?.count ?? count, joined: updated.rsvp_joined ?? !joined)
        } catch {
            override = before
            if case AppError.networkError(let m) = error, !m.isEmpty, m.count < 100, !m.hasPrefix("Server error") {
                rsvpError = m
            } else {
                rsvpError = "Couldn't update your RSVP. Please try again."
            }
        }
    }
}

/// Full-screen paging photo viewer. Pages swipe with the system; no custom
/// animation beyond that, so Reduce Motion needs nothing extra.
struct AnnouncementGalleryViewer: View {
    let images: [FSAnnouncementGalleryImage]
    let start: Int
    var onClose: () -> Void
    @State private var page: Int = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(Array(images.enumerated()), id: \.element.id) { idx, img in
                    AsyncImage(url: img.url.flatMap(URL.init(string:))) { phase in
                        if let image = phase.image { image.resizable().scaledToFit() }
                        else if phase.error != nil { Text("Couldn't load this photo.").font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment) }
                        else { ProgressView().tint(Theme.gold) }
                    }
                    .tag(idx)
                    .accessibilityLabel("Photo \(idx + 1) of \(images.count)")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.parchment)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.white.opacity(0.18)))
                    .padding(Theme.spacingSM)
            }
            .accessibilityLabel("Close photo viewer")
        }
        .preferredColorScheme(.dark)
        .onAppear { page = min(max(0, start), max(0, images.count - 1)) }
    }
}
