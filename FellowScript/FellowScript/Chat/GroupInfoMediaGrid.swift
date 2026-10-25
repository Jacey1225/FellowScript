// GroupInfoMediaGrid.swift -- task 20261023-group-info-row. Square thumbnail grid
// of the group's photos, videos and GIFs. Image/GIF tap opens the existing
// lightbox (the panel stays open beneath); video tap jumps to its message.

import SwiftUI

struct GroupInfoMediaGrid: View {
    @ObservedObject var vm: GroupMediaViewModel
    /// Closes the panel and jumps to the message (videos play inline in the bubble).
    let onShowInChat: (String) -> Void

    @State private var lightbox: FSGroupMediaItem?
    private let gap: CGFloat = 2

    var body: some View {
        Group {
            if !vm.loaded {
                if vm.loadFailed {
                    GroupInfoErrorView(category: .media) { Task { await vm.load() } }
                } else {
                    GroupInfoLoadingView(category: .media)
                }
            } else if vm.items.isEmpty && !vm.loadFailed {
                GroupInfoEmptyView(category: .media)
            } else {
                grid
            }
        }
        .task { await vm.load() }
        .fullScreenCover(item: $lightbox) { item in
            AttachmentLightboxView(kind: lightboxKind(item),
                                   remoteImageURL: item.url.flatMap(URL.init(string:)),
                                   senderLabel: item.senderName.isEmpty ? "Someone" : item.senderName,
                                   onDismiss: { lightbox = nil })
        }
    }

    private func lightboxKind(_ item: FSGroupMediaItem) -> AttachmentLightboxView.Kind {
        if item.kind == .gif, let u = item.url.flatMap(URL.init(string:)) { return .gif(u) }
        return .image(nil)
    }

    private var grid: some View {
        GeometryReader { geo in
            let inset: CGFloat = 12
            let columns = FSGroupMediaLayout.columns(forWidth: geo.size.width)
            let cell = max(44, (geo.size.width - inset * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns))
            ScrollView {
                if vm.loadFailed { GroupInfoRefreshNote { Task { await vm.load() } } }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: gap), count: columns), spacing: gap) {
                    ForEach(vm.items) { item in
                        cellView(item, size: cell)
                            .onAppear {
                                // Next page when within about one screen of the end.
                                if let idx = vm.items.firstIndex(where: { $0.id == item.id }),
                                   idx >= vm.items.count - columns * 3 {
                                    Task { await vm.loadMore() }
                                }
                            }
                    }
                }
                .padding(.horizontal, inset)
                if vm.isLoadingMore {
                    ProgressView().tint(Theme.gold).frame(maxWidth: .infinity, minHeight: 44)
                } else if vm.moreFailed {
                    Button("Couldn't load more. Try again") { Task { await vm.loadMore() } }
                        .font(.inter(Theme.fontSM, weight: .bold)).foregroundColor(Theme.gold)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
    }

    private func cellView(_ item: FSGroupMediaItem, size: CGFloat) -> some View {
        Button { open(item) } label: {
            Rectangle().fill(Theme.parchment.opacity(0.07))
                .frame(width: size, height: size)
                .overlay {
                    if let s = item.thumbURL, let url = URL(string: s) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                        }
                    }
                }
                .overlay(alignment: .bottomLeading) { badge(item) }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(FSGroupMediaLayout.accessibilityLabel(item))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Show in chat") { onShowInChat(item.messageId) }
    }

    @ViewBuilder
    private func badge(_ item: FSGroupMediaItem) -> some View {
        switch item.kind {
        case .image:
            EmptyView()
        case .gif:
            pill { Text("GIF").font(.system(size: 11, weight: .bold)) }
        case .video:
            pill {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill").font(.system(size: 9))
                    if let d = FSGroupMediaLayout.durationText(item.duration) {
                        Text(d).font(.system(size: 11, weight: .semibold))
                    }
                }
            }
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .foregroundColor(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.black.opacity(0.4), in: Capsule())
            .padding(5)
            .accessibilityHidden(true)
    }

    private func open(_ item: FSGroupMediaItem) {
        if item.kind == .video || item.url == nil {
            onShowInChat(item.messageId)
        } else {
            lightbox = item
        }
    }
}
