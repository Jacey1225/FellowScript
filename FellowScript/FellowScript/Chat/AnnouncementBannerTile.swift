// AnnouncementBannerTile.swift — the form's banner tile (task
// 20261009-announcements-advanced, part A + translucent-field style for part B).
// Replaces the dashed "Add banner photo" box: a 3:1 tile that previews the
// banner and the live title, with Upload and Stock photos pills at the bottom
// left and a remove button at the bottom right. Pills sit on their own dark
// backing so no photo can reduce their contrast; the title sits on the same
// 0.72 black scrim the widget card uses (contrast basis: scrimWorstCaseHex).

import SwiftUI
import PhotosUI

struct AnnouncementBannerTile: View {
    /// Draft preview item (title, title_color, title_font, banner_url).
    let item: FSGroupAnnouncement
    /// A locally cropped photo shown instead of `banner_url`.
    let previewImage: UIImage?
    let hasBanner: Bool
    let busy: Bool
    let showStock: Bool
    @Binding var pickerItem: PhotosPickerItem?
    var onStock: () -> Void
    var onRemove: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var pillsBelow: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXS) {
            tile
            if pillsBelow { pills }
        }
    }

    private var tile: some View {
        let url = item.banner_url.flatMap(URL.init(string:))
        return Color.clear
            .aspectRatio(AnnouncementLimits.bannerAspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.06))
            .overlay {
                if let previewImage {
                    Image(uiImage: previewImage).resizable().scaledToFill().accessibilityHidden(true)
                } else if let url {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                    }
                    .accessibilityHidden(true)
                }
            }
            .overlay { if hasBanner { Color.black.opacity(0.72).allowsHitTesting(false) } }
            .overlay(alignment: .topLeading) { titlePreview }
            .overlay(alignment: .bottomLeading) { if !pillsBelow { pills.padding(Theme.spacingSM) } }
            .overlay(alignment: .bottomTrailing) { if hasBanner { removeButton.padding(Theme.spacingXS) } }
            .overlay { if busy { ProgressView().tint(Theme.gold) } }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.28), lineWidth: 1))
    }

    private var titlePreview: some View {
        let font = AnnouncementTitleFont.resolve(item.title_font)
        return Text(item.title)
            .font(font.font(17))
            .foregroundColor(AnnouncementTitleColor.bannerColor(item.title_color))
            .lineLimit(2).minimumScaleFactor(0.7).multilineTextAlignment(.leading)
            .shadow(color: .black.opacity(0.6), radius: 1, x: 0, y: 1)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Title preview: \(item.title)")
    }

    private var pills: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.spacingXS) { uploadPill; if showStock { stockPill } }
            VStack(alignment: .leading, spacing: Theme.spacingXS) { uploadPill; if showStock { stockPill } }
        }
        .disabled(busy)
    }

    private var uploadPill: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            pillLabel("Upload", systemImage: "photo.badge.plus")
        }
        .accessibilityLabel(hasBanner ? "Upload a different photo" : "Upload a photo")
    }

    private var stockPill: some View {
        Button(action: onStock) { pillLabel("Stock photos", systemImage: "leaf") }
            .accessibilityLabel("Choose a nature stock photo")
    }

    private func pillLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.inter(Theme.fontSM, weight: .semibold))
            .foregroundColor(Theme.parchment)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Color.black.opacity(0.55))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
            .contentShape(Capsule())
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold)).foregroundColor(Theme.parchment)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(busy)
        .accessibilityLabel("Remove banner")
    }
}

/// Part B: translucent field surface. No fill color at all (the page shows
/// through), a hairline white border, and a gold border while focused. Text
/// sits on the solid page surface so AA contrast is unchanged.
struct AnnouncementTranslucentField: ViewModifier {
    var focused: Bool = false
    func body(content: Content) -> some View {
        content
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .stroke(focused ? Theme.gold : Color.white.opacity(0.28), lineWidth: focused ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

extension View {
    func announcementTranslucentField(focused: Bool = false) -> some View {
        modifier(AnnouncementTranslucentField(focused: focused))
    }
}
