// AnnouncementExtras.swift — part E attachments, non-view logic (task
// 20261009-announcements-advanced, step 8). Draft state for the form's "Add
// extras" section, client-side validation that mirrors the server's caps (the
// server stays the source of truth), and link display safety helpers.
//
// Everything here is display-only data: payment handles are text, never a link
// and never processed. Links open only through SFSafariViewController.

import Foundation
import UIKit

enum AnnouncementExtrasFlag {
    static let links    = "announcement_links"
    static let gallery  = "announcement_gallery"
    static let payments = "announcement_payments"
    static let rsvp     = "announcement_rsvp"
}

enum AnnouncementExtrasLimits {
    static let maxLinks = 5
    static let maxLinkLength = 500
    static let maxLabelLength = 60
    static let maxGallery = 6
    static let maxHandleLength = 64
    static let capacityRange = 1...9999
    static let galleryLongEdge: CGFloat = 1600
    static let galleryJpegQuality: CGFloat = 0.85
    static let paymentDisclaimer = "Payments happen outside FellowScript. FellowScript never handles money. Only pay people you know."
}

enum AnnouncementPaymentProvider: String, CaseIterable, Identifiable {
    case venmo, cashapp, paypal, zelle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .venmo: return "Venmo"
        case .cashapp: return "Cash App"
        case .paypal: return "PayPal"
        case .zelle: return "Zelle"
        }
    }
    var placeholder: String {
        switch self {
        case .venmo: return "@username"
        case .cashapp: return "$cashtag"
        case .paypal: return "PayPal.Me name"
        case .zelle: return "Email or phone"
        }
    }
}

/// Link parsing and display safety. Only http/https with a host is ever
/// accepted or opened; links never load into a web view of our own.
enum AnnouncementLinkSafety {
    /// Parsed, scheme-checked URL or nil. A missing scheme is treated as https.
    static func parse(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= AnnouncementExtrasLimits.maxLinkLength else { return nil }
        if s.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) != nil { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let comps = URLComponents(string: s),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              comps.user == nil, comps.password == nil,
              let host = comps.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              let url = comps.url else { return nil }
        return url
    }

    /// The domain shown beside every link so the real destination is visible.
    static func displayHost(_ url: URL) -> String {
        var h = (url.host ?? "").lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// True for internationalized hosts (non-ASCII or punycode labels), which
    /// can imitate a familiar domain.
    static func isLookalikeRisk(host: String) -> Bool {
        host.unicodeScalars.contains { !$0.isASCII } || host.split(separator: ".").contains { $0.hasPrefix("xn--") }
    }
}

struct AnnouncementExtrasDraft: Equatable {
    struct LinkRow: Identifiable, Equatable {
        let id = UUID()
        var url: String = ""
        var label: String = ""
    }
    struct GalleryRow: Identifiable, Equatable {
        let id = UUID()
        let key: String
        let remoteURL: URL?
        let preview: UIImage?
        static func == (a: GalleryRow, b: GalleryRow) -> Bool { a.id == b.id }
    }

    var links: [LinkRow] = []
    var gallery: [GalleryRow] = []
    var isEvent = false
    var handles: [String: String] = [:]
    var rsvpOn = false
    var capacity = 20

    init(from a: FSGroupAnnouncement?) {
        links = (a?.links ?? []).map { LinkRow(url: $0.url, label: $0.label ?? "") }
        gallery = (a?.gallery ?? []).map { GalleryRow(key: $0.key, remoteURL: $0.url.flatMap(URL.init(string:)), preview: nil) }
        isEvent = a?.is_event ?? false
        for h in a?.payment_handles ?? [] { handles[h.provider] = h.handle }
        if let c = a?.capacity { rsvpOn = true; capacity = c }
    }

    /// Rows with a non-empty URL, normalized for sending.
    var cleanedLinks: [FSAnnouncementLink] {
        links.compactMap { row in
            let raw = row.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let url = AnnouncementLinkSafety.parse(raw) else { return nil }
            let label = row.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return FSAnnouncementLink(url: url.absoluteString, label: label.isEmpty ? nil : label)
        }
    }

    var cleanedHandles: [FSPaymentHandle] {
        AnnouncementPaymentProvider.allCases.compactMap { p in
            let h = (handles[p.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return h.isEmpty ? nil : FSPaymentHandle(provider: p.rawValue, handle: h)
        }
    }

    func linkError(_ row: LinkRow) -> String? {
        let raw = row.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }
        if AnnouncementLinkSafety.parse(raw) == nil { return "Enter a web address like example.com." }
        return nil
    }

    func handleError(_ provider: AnnouncementPaymentProvider) -> String? {
        let h = (handles[provider.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty { return nil }
        if h.count > AnnouncementExtrasLimits.maxHandleLength { return "Too long." }
        // Mirrors the server: never accept something that looks like a card or account number.
        let digits = h.filter(\.isNumber)
        if digits.count >= 13 { return "Enter a username, email or phone, not a card or account number." }
        return nil
    }

    /// First reason the section can't be saved as it stands, or nil.
    func blockingError(links on: Bool, payments: Bool) -> String? {
        if on {
            if links.contains(where: { linkError($0) != nil }) { return "Fix the highlighted link." }
        }
        if payments, isEvent, AnnouncementPaymentProvider.allCases.contains(where: { handleError($0) != nil }) {
            return "Fix the highlighted payment handle."
        }
        return nil
    }

    /// How many extras are filled in (shown as a badge on the collapsed row).
    func count(links l: Bool, gallery g: Bool, payments p: Bool, rsvp r: Bool) -> Int {
        var n = 0
        if l { n += cleanedLinks.count }
        if g { n += gallery.count }
        if p, isEvent { n += 1 }
        if r, rsvpOn { n += 1 }
        return n
    }

    /// Writes only what changed vs `original`, and only for enabled flags
    /// (a flag-off key sent to the server is a 422).
    func apply(to draft: inout FSAnnouncementDraft, original o: FSGroupAnnouncement?,
               links linksOn: Bool, gallery galleryOn: Bool, payments paymentsOn: Bool, rsvp rsvpOn_: Bool) {
        if linksOn {
            let cur = cleanedLinks
            let orig = (o?.links ?? []).map { FSAnnouncementLink(url: $0.url, label: ($0.label ?? "").isEmpty ? nil : $0.label) }
            if cur != orig { draft.links = cur.isEmpty ? .clear : .set(cur) }
        }
        if galleryOn {
            let cur = gallery.map(\.key)
            let orig = (o?.gallery ?? []).map(\.key)
            if cur != orig { draft.galleryKeys = cur.isEmpty ? .clear : .set(cur) }
        }
        if paymentsOn {
            let origEvent = o?.is_event ?? false
            let curHandles = isEvent ? cleanedHandles : []
            let origHandles = o?.payment_handles ?? []
            if isEvent != origEvent { draft.isEvent = .set(isEvent) }
            if Set(curHandles.map { "\($0.provider)|\($0.handle)" }) != Set(origHandles.map { "\($0.provider)|\($0.handle)" }) {
                draft.paymentHandles = curHandles.isEmpty ? .clear : .set(curHandles)
            }
        }
        if rsvpOn_ {
            let cur: Int? = rsvpOn ? min(max(capacity, AnnouncementExtrasLimits.capacityRange.lowerBound), AnnouncementExtrasLimits.capacityRange.upperBound) : nil
            if cur != o?.capacity { draft.capacity = cur.map { .set($0) } ?? .clear }
        }
    }
}

/// Downscales a picked photo to a JPEG suitable for the gallery upload.
enum AnnouncementGalleryProcessor {
    static func jpeg(from data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let img = UIImage(data: data), img.size.width > 0, img.size.height > 0 else { return nil }
            let long = max(img.size.width, img.size.height)
            let scale = min(1, AnnouncementExtrasLimits.galleryLongEdge / long)
            let size = CGSize(width: (img.size.width * scale).rounded(), height: (img.size.height * scale).rounded())
            let fmt = UIGraphicsImageRendererFormat.default()
            fmt.scale = 1
            fmt.opaque = true
            let out = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
                UIColor.black.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
                img.draw(in: CGRect(origin: .zero, size: size))
            }
            return out.jpegData(compressionQuality: AnnouncementExtrasLimits.galleryJpegQuality)
        }.value
    }
}
