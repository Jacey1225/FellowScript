// AnnouncementStockBanners.swift — bundled nature photo set + picker sheet
// (task 20261009-announcements-advanced, part A, design-notes.md "A. Stock
// photos"). The photos ship inside the app (Resources/NatureBanners/), so there
// is no network, no hotlinking and no server surface: picking one hands the
// image to the same crop -> JPEG -> upload pipeline a library photo uses.
// Provenance and license for every image: Resources/NatureBanners/CREDITS.md
// and the manifest (nature-banners.json) this file reads.

import SwiftUI
import UIKit
import ImageIO

struct AnnouncementStockPhoto: Decodable, Identifiable, Equatable {
    let id: String
    let file: String        // bundle resource name without extension
    let category: String    // mountains | forest | water | sky
    let alt: String         // VoiceOver description
    let author: String
    let license: String
}

enum AnnouncementStockCatalog {
    /// Client-side switch (no server flag): lets the picker be turned off in one place.
    static let enabled = true
    static let manifestName = "nature-banners"
    /// Loaded once; empty (button hidden) if the manifest is missing or unreadable.
    static let shared: [AnnouncementStockPhoto] = load()

    static let categories: [(key: String?, title: String)] = [
        (nil, "All"), ("mountains", "Mountains"), ("forest", "Forest"), ("water", "Water"), ("sky", "Sky and land"),
    ]

    /// Fail-closed: a missing/corrupt manifest yields an empty set, which hides the button.
    static func load(bundle: Bundle = .main) -> [AnnouncementStockPhoto] {
        guard enabled,
              let url = bundle.url(forResource: manifestName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let photos = try? JSONDecoder().decode([AnnouncementStockPhoto].self, from: data) else { return [] }
        return photos.filter { fileURL($0, bundle: bundle) != nil }
    }

    static func fileURL(_ p: AnnouncementStockPhoto, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: p.file, withExtension: "jpg")
            ?? bundle.url(forResource: p.file, withExtension: "jpg", subdirectory: "NatureBanners")
    }

    /// Full-size image for the crop step.
    static func fullImage(_ p: AnnouncementStockPhoto, bundle: Bundle = .main) throws -> UIImage {
        guard let url = fileURL(p, bundle: bundle) else { throw AnnouncementCropError.decode }
        return try AnnouncementCropMath.decode(data: Data(contentsOf: url))
    }

    private static let thumbCache = NSCache<NSString, UIImage>()

    /// Memory-light thumbnail (ImageIO downsample; never decodes the full photo).
    static func thumbnail(_ p: AnnouncementStockPhoto, maxPixel: CGFloat = 600, bundle: Bundle = .main) -> UIImage? {
        if let hit = thumbCache.object(forKey: p.id as NSString) { return hit }
        guard let url = fileURL(p, bundle: bundle),
              let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = UIImage(cgImage: cg)
        thumbCache.setObject(img, forKey: p.id as NSString)
        return img
    }
}

/// Sheet: category chips, 2-column grid, "Use photo" bar. Confirm returns the
/// full image via `onPick`; the caller opens the crop step.
struct AnnouncementStockPicker: View {
    let photos: [AnnouncementStockPhoto]
    var onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var category: String?
    @State private var selectedId: String?
    @State private var failed = false

    private var visible: [AnnouncementStockPhoto] {
        guard let category else { return photos }
        return photos.filter { $0.category == category }
    }
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                chips
                ScrollView {
                    if visible.isEmpty {
                        Text("No photos here.").font(.inter(Theme.fontSM)).foregroundColor(Theme.parchment.opacity(0.7))
                            .padding(Theme.spacingLG)
                    }
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(visible) { p in thumb(p) }
                    }
                    .padding(.horizontal, Theme.spacingMD).padding(.bottom, Theme.spacingMD)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Nature photos")
                }
                bottomBar
            }
            .warmBloomBackground()
            .navigationTitle("Nature photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(Theme.gold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.spacingSM) {
                ForEach(AnnouncementStockCatalog.categories, id: \.title) { c in
                    let on = category == c.key
                    Button { category = c.key } label: {
                        Text(c.title)
                            .font(.inter(Theme.fontXS, weight: .semibold))
                            .foregroundColor(on ? Theme.gold : Theme.parchment.opacity(0.8))
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(on ? Theme.gold.opacity(0.15) : Color.clear)
                            .overlay(Capsule().stroke(on ? Theme.borderGold : Theme.borderGoldDim, lineWidth: 1))
                            .clipShape(Capsule()).contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.title)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, Theme.spacingMD)
        }
    }

    private func thumb(_ p: AnnouncementStockPhoto) -> some View {
        let selected = selectedId == p.id
        return Button {
            withMotionAwareAnimation(.spring(response: 0.3, dampingFraction: 0.8), reduceMotion: reduceMotion) { selectedId = p.id }
            failed = false
        } label: {
            StockThumb(photo: p)
                .aspectRatio(3.0 / 2.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(selected ? Theme.gold : Color.white.opacity(0.18), lineWidth: selected ? 2 : 1))
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 22))
                            .foregroundStyle(.black, Theme.gold).padding(6)
                    }
                }
                .scaleEffect(selected && !reduceMotion ? 1 : 0.98)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(p.alt)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var bottomBar: some View {
        VStack(spacing: Theme.spacingXS) {
            if failed {
                Text("Couldn't set that photo. Try again.")
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.error)
            }
            Button {
                guard let p = photos.first(where: { $0.id == selectedId }) else { return }
                do {
                    let img = try AnnouncementStockCatalog.fullImage(p)
                    onPick(img)
                    dismiss()
                } catch { failed = true }
            } label: {
                Text("Use photo")
                    .font(.inter(Theme.fontSM, weight: .bold)).foregroundColor(Color(hex: "#1A1108"))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(selectedId == nil ? Theme.gold.opacity(0.35) : Theme.gold)
                    .clipShape(Capsule())
            }
            .disabled(selectedId == nil)
            .accessibilityHint("Opens the crop step")
        }
        .padding(Theme.spacingMD)
        .background(Theme.bgPage.opacity(0.9))
    }
}

private struct StockThumb: View {
    let photo: AnnouncementStockPhoto
    @State private var image: UIImage?

    var body: some View {
        Color.white.opacity(0.06)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipped()
            .task(id: photo.id) {
                let p = photo
                image = await Task.detached(priority: .userInitiated) { AnnouncementStockCatalog.thumbnail(p) }.value
            }
    }
}
