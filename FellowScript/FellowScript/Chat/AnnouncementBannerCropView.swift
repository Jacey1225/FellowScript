// AnnouncementBannerCropView.swift — fixed 3:1 pan/zoom crop step for the
// announcement banner (task 20260929-announcement-banner-crop-list-style,
// design-notes.md "Crop UI"). Confirms with the baked JPEG data; Cancel leaves
// the caller's banner untouched. No animated snap/inertia, so reduced motion is
// honored by construction.

import SwiftUI

struct AnnouncementBannerCropView: View {
    let image: UIImage
    var onCancel: () -> Void
    var onConfirm: (Data) -> Void

    @State private var zoom: CGFloat = 1
    @State private var offset: CGPoint = .zero
    @State private var dragBase: CGPoint?
    @State private var pinchBase: (zoom: CGFloat, offset: CGPoint)?
    @State private var frame: CGSize = .zero
    @State private var encoding = false
    @State private var error: String?

    private let margin: CGFloat = 20
    private let step: CGFloat = 0.25
    private let nudge: CGFloat = 12

    private let surface = Color(white: 0.05)

    /// Layout (task 20260929-announcement-title-color-crop-layer-fix): opaque
    /// surface root; header is a safe-area top inset (never under the clock or
    /// Dynamic Island); the photo is clipped to the crop frame so no pixel can
    /// bleed under the header or the opaque controls panel below; gestures
    /// attach to the clipped frame only.
    var body: some View {
        ZStack {
            surface.ignoresSafeArea()
            VStack(spacing: 0) {
                GeometryReader { geo in
                    let fs = AnnouncementCropMath.frameSize(width: max(1, geo.size.width - margin * 2))
                    cropFrame(fs)
                        .frame(width: fs.width, height: fs.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .onAppear { setFrame(fs) }
                        .onChange(of: fs) { _, new in setFrame(new) }
                }
                .clipped()
                panel
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            header
                .background(surface.ignoresSafeArea(edges: .top))
                .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1) }
        }
        .preferredColorScheme(.dark)
    }

    private var panel: some View {
        VStack(spacing: Theme.spacingSM) {
            Text("Drag to position. Pinch or use the slider to zoom.")
                .font(.inter(Theme.fontXS)).foregroundColor(Theme.parchment.opacity(0.7))
                .multilineTextAlignment(.center)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.inter(Theme.fontXS)).foregroundColor(Theme.error)
                    .accessibilityLabel(error)
            }
            ViewThatFits(in: .horizontal) {
                controls(stacked: false)
                controls(stacked: true)
            }
        }
        .padding(.vertical, Theme.spacingSM)
        .frame(maxWidth: .infinity)
        .background(surface)
        .zIndex(1)
    }

    private var header: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .font(.inter(Theme.fontSM)).foregroundColor(Theme.gold)
                .frame(minWidth: 44, minHeight: 44).fixedSize()
                .disabled(encoding)
            Spacer()
            Text("Crop banner").font(.inter(Theme.fontSM, weight: .semibold)).foregroundColor(Theme.parchment)
                .lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: done) {
                if encoding { ProgressView().tint(Theme.gold) } else { Text("Done").fontWeight(.bold) }
            }
            .font(.inter(Theme.fontSM)).foregroundColor(Theme.gold)
            .frame(minWidth: 44, minHeight: 44).fixedSize()
            .disabled(encoding || frame.width <= 0)
        }
        .padding(.horizontal, margin)
    }

    private func cropFrame(_ fs: CGSize) -> some View {
        let d = AnnouncementCropMath.displaySize(natural: image.size, frame: fs, zoom: zoom)
        return ZStack(alignment: .topLeading) {
            Image(uiImage: image).resizable()
                .frame(width: d.width, height: d.height)
                .offset(x: offset.x, y: offset.y)
        }
        .frame(width: fs.width, height: fs.height, alignment: .topLeading)
        .clipped()   // the photo never renders outside the 3:1 frame
        .overlay {
            Path { p in
                for i in 1...2 {
                    let x = fs.width * CGFloat(i) / 3, y = fs.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: fs.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: fs.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
            .allowsHitTesting(false)
        }
        .overlay(Rectangle().stroke(Theme.gold, lineWidth: 2).allowsHitTesting(false))
        .contentShape(Rectangle())
        .gesture(dragGesture(fs).simultaneously(with: magnifyGesture(fs)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Banner crop area")
        .accessibilityValue("Zoom \(Int((zoom * 100).rounded())) percent")
        .accessibilityHint("Adjust to zoom. Use the actions to move the photo.")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: setZoom(zoom + step)
            case .decrement: setZoom(zoom - step)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Move left") { move(nudge * 2, 0) }
        .accessibilityAction(named: "Move right") { move(-nudge * 2, 0) }
        .accessibilityAction(named: "Move up") { move(0, nudge * 2) }
        .accessibilityAction(named: "Move down") { move(0, -nudge * 2) }
        .accessibilityAction(named: "Reset") { reset() }
    }

    @ViewBuilder
    private func controls(stacked: Bool) -> some View {
        let minus = Button { setZoom(zoom - step) } label: { Image(systemName: "minus") }
            .frame(width: 44, height: 44).accessibilityLabel("Zoom out")
        let plus = Button { setZoom(zoom + step) } label: { Image(systemName: "plus") }
            .frame(width: 44, height: 44).accessibilityLabel("Zoom in")
        let resetButton = Button("Reset") { reset() }
            .font(.inter(Theme.fontSM)).frame(minWidth: 44, minHeight: 44).fixedSize().accessibilityLabel("Reset crop")
        let slider = Slider(value: Binding(get: { Double(zoom) }, set: { setZoom(CGFloat($0)) }),
                            in: 1...Double(AnnouncementLimits.cropZoomMax))
            .tint(Theme.gold).frame(minHeight: 44).accessibilityLabel("Zoom")
        Group {
            if stacked {
                VStack(spacing: Theme.spacingXS) {
                    slider
                    HStack(spacing: Theme.spacingSM) { minus; plus; resetButton }
                }
            } else {
                HStack(spacing: Theme.spacingSM) { minus; slider; plus; resetButton }
            }
        }
        .foregroundColor(Theme.gold)
        .padding(.horizontal, margin)
        .disabled(encoding)
    }

    // ── Gestures ─────────────────────────────────────────────────────────────
    private func dragGesture(_ fs: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragBase == nil { dragBase = offset }
                let base = dragBase ?? offset
                offset = AnnouncementCropMath.clampOffset(
                    CGPoint(x: base.x + v.translation.width, y: base.y + v.translation.height),
                    natural: image.size, frame: fs, zoom: zoom)
            }
            .onEnded { _ in dragBase = nil }
    }

    private func magnifyGesture(_ fs: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchBase == nil { pinchBase = (zoom, offset) }
                guard let b = pinchBase else { return }
                let r = AnnouncementCropMath.zoomAround(zoom: b.zoom, offset: b.offset, to: b.zoom * v.magnification,
                                                        anchor: v.startLocation, natural: image.size, frame: fs)
                zoom = r.zoom; offset = r.offset
            }
            .onEnded { _ in pinchBase = nil }
    }

    // ── State helpers ────────────────────────────────────────────────────────
    private func setFrame(_ fs: CGSize) {
        let first = frame == .zero
        frame = fs
        if first { offset = AnnouncementCropMath.centeredOffset(natural: image.size, frame: fs, zoom: zoom) }
        else { offset = AnnouncementCropMath.clampOffset(offset, natural: image.size, frame: fs, zoom: zoom) }
    }

    private func setZoom(_ z: CGFloat) {
        guard frame.width > 0 else { return }
        let r = AnnouncementCropMath.zoomAround(zoom: zoom, offset: offset, to: z,
                                                anchor: CGPoint(x: frame.width / 2, y: frame.height / 2),
                                                natural: image.size, frame: frame)
        zoom = r.zoom; offset = r.offset
    }

    private func move(_ dx: CGFloat, _ dy: CGFloat) {
        offset = AnnouncementCropMath.clampOffset(CGPoint(x: offset.x + dx, y: offset.y + dy),
                                                  natural: image.size, frame: frame, zoom: zoom)
    }

    private func reset() {
        zoom = 1
        offset = AnnouncementCropMath.centeredOffset(natural: image.size, frame: frame, zoom: 1)
    }

    private func done() {
        guard !encoding, frame.width > 0 else { return }
        encoding = true; error = nil
        do {
            let data = try AnnouncementCropMath.renderJPEG(image: image, frame: frame, zoom: zoom, offset: offset)
            encoding = false
            onConfirm(data)
        } catch {
            encoding = false
            self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't save the crop. Please try again."
        }
    }
}
