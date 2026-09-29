// AnnouncementBannerImage.swift — one canonical-aspect banner box shared by the
// form preview, list row and detail view. Legacy (non-3:1) images render
// cover-fit, center-anchored inside the clipped fixed-aspect frame.

import SwiftUI

struct AnnouncementBannerImage: View {
    enum Source { case url(URL), image(UIImage) }
    let source: Source
    var cornerRadius: CGFloat = 12

    var body: some View {
        Color.white.opacity(0.06)
            .aspectRatio(AnnouncementLimits.bannerAspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                switch source {
                case .url(let url):
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                    }
                case .image(let img):
                    Image(uiImage: img).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}
