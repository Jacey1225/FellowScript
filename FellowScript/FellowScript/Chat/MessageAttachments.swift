// MessageAttachments.swift
// Task 20260904-messaging-attachments — composer attach affordance, GIF
// search sheet, staged (pre-send) attachment preview, and per-kind
// attachment rendering inside the existing message bubble. Built against
// design-notes.md (design gate §1–§9) and backend step 2's wire contract:
// see FSMessage/FSAttachmentMeta/FSUploadURLInfo/FSGifResult in Models.swift.
//
// DEPENDENCY: Theme.swift, Models.swift, MockDataService.swift (DataServiceProtocol)

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVKit
import ImageIO
import Combine

// ── Local (pre-send / just-sent) preview cache ───────────────────────────────
// Keyed by FSMessage.id on ChatThreadViewModel. The sender's own optimistic
// echo (ChatThreadViewModel.sendMessage) is never re-delivered by the server
// (the existing self-echo guard in receiveLoop() drops it), and a freshly
// uploaded object's presigned GET is only ever resolved server-side — so
// without this, the sender would never see their own just-sent image/video
// render at all until the next full history reload. GIF needs no local
// preview: its provider URL (attachment_meta.url) is already a public,
// immediately-usable URL for both the optimistic echo and the real message.
struct LocalAttachmentPreview {
    var image:    UIImage? = nil
    var videoURL: URL?     = nil
}

// ── Staged (picked, not yet sent) attachment ─────────────────────────────────
enum StagedAttachmentUploadState: Equatable {
    case idle                       // GIF: nothing to upload, ready to send immediately
    case uploading
    case uploaded(objectKey: String)
    case failed
}

/// One picked-but-unsent attachment. A class (not a struct) so its
/// `uploadState` can be observed live by the staged-preview chip while the
/// upload runs, per design gate §3.
final class StagedAttachment: ObservableObject, Identifiable {
    let id = UUID().uuidString
    let kind:        FSAttachmentKind
    let contentType: String
    let fileData:    Data?
    let fileName:    String?
    let width:       Int?
    let height:      Int?
    let image:       UIImage?
    let videoURL:    URL?
    let gifResult:   FSGifResult?
    @Published var uploadState: StagedAttachmentUploadState

    init(kind: FSAttachmentKind, contentType: String = "", fileData: Data? = nil,
         fileName: String? = nil, width: Int? = nil, height: Int? = nil,
         image: UIImage? = nil, videoURL: URL? = nil, gifResult: FSGifResult? = nil) {
        self.kind = kind
        self.contentType = contentType
        self.fileData = fileData
        self.fileName = fileName
        self.width = width
        self.height = height
        self.image = image
        self.videoURL = videoURL
        self.gifResult = gifResult
        // A GIF is stage-and-send-immediately (design gate §3) — no bytes of
        // ours to upload, so there's nothing to wait on.
        self.uploadState = (kind == .gif) ? .idle : .uploading
    }

    // task 20260905-stagedattachment-deinit-crash: this is NOT dead/defensive
    // code -- do not remove without re-reading that task's intake spec first.
    // On an iOS 18.5 simulator/device under Xcode 26.6 (deployment target
    // 18.0, below this toolchain's native SDK floor), a MainActor-isolated
    // class's *synthesized* deinit gets routed through
    // `swift_task_deinitOnExecutorMainActorBackDeploy`, a Swift-runtime
    // back-deployment compatibility shim that has a real memory-corruption
    // bug for at least some compiled class shapes (empirically reproduced
    // for this exact class, and independently for an unrelated third-party
    // class -- see that task's intake spec for the full evidence trail).
    // An explicit `nonisolated deinit` routes teardown around that shim
    // entirely, sidestepping the bug regardless of its precise trigger
    // condition. This has no behavioral effect on any OS version -- it only
    // changes which executor tears the instance down on, and this class
    // holds nothing that requires main-actor-isolated cleanup.
    nonisolated deinit {}

    /// `attachment_meta` to send alongside this attachment, matching backend
    /// step 2's wire contract exactly (`{"filename": ...}` for file,
    /// `{"url","preview_url","width","height"}` for gif; image/video carry
    /// their natural dimensions only, per design gate §4's reflow note).
    var outgoingMeta: [String: Any] {
        switch kind {
        case .file:
            return ["filename": fileName ?? "file"]
        case .gif:
            guard let gifResult else { return [:] }
            return ["url": gifResult.url, "preview_url": gifResult.preview_url,
                    "width": gifResult.width, "height": gifResult.height]
        case .image, .video:
            var meta: [String: Any] = [:]
            if let width  { meta["width"]  = width }
            if let height { meta["height"] = height }
            return meta
        }
    }
}

// ── Attach picker row (task 20260904-attach-picker-layout-polish, follow-up
// to design gate §1) ─────────────────────────────────────────────────────────
// Renders inline (not as a `.sheet`) directly above the composer's text
// field, in the same "transient element between thread and composer" slot
// the staged-attachment chip already uses -- a `.sheet`/`.presentationDetents`
// bottom modal can't be re-anchored mid-screen, so this replaces it with a
// plain conditional row in ChatThreadView's composer VStack. Each option is
// now its own gold `PillButton` (icon + title) laid out in a single
// horizontal row instead of a stacked column of plain list rows.
struct AttachPickerRow: View {
    var onPickPhotoVideo: () -> Void
    var onPickFile:       () -> Void
    var onPickGif:        () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.spacingSM) {
                pill(title: "Photo & Video", systemIcon: "photo.on.rectangle", action: onPickPhotoVideo)
                pill(title: "File", systemIcon: "doc", action: onPickFile)
                pill(title: "GIF", systemIcon: "face.smiling", action: onPickGif)
            }
            .padding(.horizontal, Theme.spacingMD)
        }
        .padding(.top, Theme.spacingXS)
        .padding(.bottom, Theme.spacingSM)
    }

    // 44pt minimum tap target (Q14) over PillButton's own visually-shorter
    // (~38pt) rendered height -- same enlarged-hit-area technique already
    // used by the composer's attachButton, applied here since PillButton
    // itself (shared with the chat header's "Schedule" pill and
    // SessionCreatorSheet) isn't modified.
    private func pill(title: String, systemIcon: String, action: @escaping () -> Void) -> some View {
        PillButton(title: title, systemIcon: systemIcon, action: action)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(title)
    }
}

// ── Native pickers (design gate §1 — OS chrome here is expected, not a Q12 violation) ──

struct PhotoVideoPicker: UIViewControllerRepresentable {
    var onPicked: (StagedAttachment?) -> Void
    // dependency-errors #6: a picker operation that genuinely fails (copy/
    // decode error, unsupported item) previously vanished into the same
    // `onPicked(nil)` as a plain user cancellation, so the caller had no way
    // to tell "you cancelled" from "that broke" and never surfaced anything.
    // Cancellation (no item selected) still calls only `onPicked(nil)`
    // silently; a genuine failure additionally calls `onFailure`.
    var onFailure: () -> Void = {}

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 1 // single-attachment-per-message schema (design gate, wire contract)
        config.filter = .any(of: [.images, .videos])
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked, onFailure: onFailure) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: (StagedAttachment?) -> Void
        let onFailure: () -> Void
        init(onPicked: @escaping (StagedAttachment?) -> Void, onFailure: @escaping () -> Void = {}) {
            self.onPicked = onPicked
            self.onFailure = onFailure
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            // No item selected -- the user backed out of the picker. Not a
            // failure; stay silent, matching the existing cancel affordance.
            guard let result = results.first else { onPicked(nil); return }
            let provider = result.itemProvider

            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                    guard let url else {
                        DispatchQueue.main.async { self.onPicked(nil); self.onFailure() }
                        return
                    }
                    // `url` is only valid for the duration of this callback —
                    // copy to a stable temp location before touching it later
                    // (upload body, local inline-playback preview).
                    let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                    do {
                        try? FileManager.default.removeItem(at: tempURL)
                        try FileManager.default.copyItem(at: url, to: tempURL)
                        let data = try Data(contentsOf: tempURL)
                        let contentType = Self.videoMimeType(forExtension: ext)
                        let attachment = StagedAttachment(kind: .video, contentType: contentType,
                                                           fileData: data, videoURL: tempURL)
                        DispatchQueue.main.async { self.onPicked(attachment) }
                    } catch {
                        DispatchQueue.main.async { self.onPicked(nil); self.onFailure() }
                    }
                }
            } else if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    guard let image = object as? UIImage, let data = image.jpegData(compressionQuality: 0.9) else {
                        DispatchQueue.main.async { self.onPicked(nil); self.onFailure() }
                        return
                    }
                    let attachment = StagedAttachment(kind: .image, contentType: "image/jpeg", fileData: data,
                                                       width: Int(image.size.width), height: Int(image.size.height),
                                                       image: image)
                    DispatchQueue.main.async { self.onPicked(attachment) }
                }
            } else {
                // Selected item is neither a movie nor an image we can load
                // (an unsupported item type slipped past the PHPicker
                // filter) -- a genuine failure, not a cancellation.
                onPicked(nil)
                onFailure()
            }
        }

        static func videoMimeType(forExtension ext: String) -> String {
            ext.lowercased() == "mp4" ? "video/mp4" : "video/quicktime"
        }
    }
}

struct DocumentPicker: UIViewControllerRepresentable {
    var onPicked: (StagedAttachment?) -> Void
    // dependency-errors #6: see PhotoVideoPicker's onFailure above -- same
    // cancel-vs-failure distinction, since documentPickerWasCancelled already
    // gives us an explicit cancel signal separate from didPickDocumentsAt.
    var onFailure: () -> Void = {}

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Filtered to the allowlisted extensions as a client-side nicety only
        // — not a security boundary (design gate §1); the server enforces
        // the real per-kind allowlist (security step 1).
        let allowedTypes: [UTType] = [
            .pdf, .plainText,
            UTType(filenameExtension: "doc")  ?? .data,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "xlsx") ?? .data,
        ]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked, onFailure: onFailure) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: (StagedAttachment?) -> Void
        let onFailure: () -> Void
        init(onPicked: @escaping (StagedAttachment?) -> Void, onFailure: @escaping () -> Void = {}) {
            self.onPicked = onPicked
            self.onFailure = onFailure
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // This delegate method only fires with a genuine selection --
            // cancellation goes through documentPickerWasCancelled below --
            // so every early-return here is a real failure, not a cancel.
            guard let url = urls.first else { onPicked(nil); onFailure(); return }
            guard url.startAccessingSecurityScopedResource() else { onPicked(nil); onFailure(); return }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else { onPicked(nil); onFailure(); return }
            let contentType = Self.mimeType(forExtension: url.pathExtension)
            let attachment = StagedAttachment(kind: .file, contentType: contentType, fileData: data,
                                               fileName: url.lastPathComponent)
            onPicked(attachment)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPicked(nil)
        }

        static func mimeType(forExtension ext: String) -> String {
            switch ext.lowercased() {
            case "pdf":  return "application/pdf"
            case "txt":  return "text/plain"
            case "doc":  return "application/msword"
            case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            default:     return "application/octet-stream"
            }
        }
    }
}

// ── GIF-search sheet (design gate §2) ────────────────────────────────────────

@MainActor
final class GifSearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [FSGifResult] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    private var searchTask: Task<Void, Never>?

    /// Debounces ~350ms before calling the search endpoint (design gate §2 —
    /// the endpoint is rate-limited server-side at 30/min, so this isn't
    /// merely a UX nicety).
    func queryChanged(_ newValue: String, service: DataServiceProtocol) {
        searchTask?.cancel()
        errorMessage = nil
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isLoading = false
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            self.isLoading = true
            do {
                let results = try await service.searchGifs(query: trimmed)
                guard !Task.isCancelled else { return }
                self.results = results
                self.isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                // Warm, non-technical copy (design gate §2/§7) — never the
                // raw HTTP status or provider error text.
                self.errorMessage = "Couldn't load GIFs right now — try again in a moment."
                self.isLoading = false
            }
        }
    }
}

struct GifSearchSheet: View {
    let service: DataServiceProtocol
    var onSelect: (StagedAttachment) -> Void

    @StateObject private var vm = GifSearchViewModel()
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(spacing: Theme.spacingSM) {
            searchField
            content
        }
        .padding(Theme.spacingSM)
        .background(Theme.bgPage.ignoresSafeArea())
        .presentationDragIndicator(.visible)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(Theme.textSecondary)
            TextField("", text: $vm.query, prompt: Text("Search GIFs").foregroundColor(Theme.textSecondary))
                .font(.inter(Theme.fontBody))
                .foregroundColor(Theme.parchment)
                .onChange(of: vm.query) { newValue in
                    vm.queryChanged(newValue, service: service)
                }
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05))
        .overlay(Capsule().stroke(Theme.borderGoldDim, lineWidth: 1))
        .clipShape(Capsule())
        .accessibilityLabel("Search GIFs")
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading {
            centered { ProgressView().tint(Theme.gold) }
        } else if let error = vm.errorMessage {
            centered {
                Text(error)
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.spacingLG)
            }
        } else if vm.results.isEmpty {
            centered {
                Text(vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "Search for a GIF to send."
                     : "No results")
                    .font(.inter(Theme.fontSM))
                    .foregroundColor(Theme.textSecondary)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(vm.results) { gif in
                        Button {
                            onSelect(StagedAttachment(kind: .gif, width: gif.width, height: gif.height, gifResult: gif))
                            dismiss()
                        } label: {
                            AsyncImage(url: URL(string: gif.preview_url)) { phase in
                                if let image = phase.image {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Rectangle().fill(Theme.gold.opacity(0.10))
                                }
                            }
                            .frame(minHeight: 88)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("GIF result")
                    }
                }
            }
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// ── Staged (pre-send) attachment preview chip (design gate §3) ──────────────
struct StagedAttachmentChipView: View {
    @ObservedObject var attachment: StagedAttachment
    var onRemove: () -> Void
    var onRetry:  () -> Void

    var body: some View {
        HStack(spacing: Theme.spacingSM) {
            thumbnail

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.inter(Theme.fontXS))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                if case .failed = attachment.uploadState {
                    Button(action: onRetry) {
                        Text("Couldn't send — tap to retry")
                            .font(.inter(Theme.fontXXS))
                            .foregroundColor(Theme.error)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)

            if case .uploading = attachment.uploadState {
                ProgressView().tint(Theme.gold).scaleEffect(0.75)
            }

            // No confirmation dialog — undo-after-the-fact per this
            // project's stated interaction preference (design gate §3).
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")
        }
        .padding(.leading, Theme.spacingSM)
        .padding(.trailing, Theme.spacingXS)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.045))
        .overlay(Capsule().stroke(Theme.borderGoldFaint, lineWidth: 1))
        .clipShape(Capsule())
        .topEdgeHighlight(Capsule())
        .padding(.horizontal, Theme.spacingSM)
        .padding(.top, Theme.spacingXS)
    }

    private var label: String {
        switch attachment.kind {
        case .image: return "Photo"
        case .video: return "Video"
        case .file:  return attachment.fileName ?? "File"
        case .gif:   return "GIF"
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let image = attachment.image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if attachment.kind == .gif, let previewUrl = attachment.gifResult?.preview_url {
                AsyncImage(url: URL(string: previewUrl)) { phase in
                    if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) }
                    else { Rectangle().fill(Theme.gold.opacity(0.12)) }
                }
            } else {
                Image(systemName: attachment.kind == .video ? "video.fill" : "doc.fill")
                    .foregroundColor(Theme.gold)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
    }
}

// ── Rejected-file / upload-failure inline copy (design gate §3/§7) ──────────
enum AttachmentErrorCopy {
    static func forRejectedContentType() -> String {
        "That file type isn't supported here."
    }

    /// Phrased from security step 1's actual concrete per-kind limits.
    static func forOversize(kind: FSAttachmentKind) -> String {
        switch kind {
        case .image: return "Photos can be up to 15MB."
        case .video: return "Videos can be up to 250MB."
        case .file:  return "Files can be up to 50MB."
        case .gif:   return "That GIF couldn't be sent."
        }
    }
}

// ── Minimal animated-GIF renderer ────────────────────────────────────────────
// SwiftUI's `Image`/`AsyncImage` only ever decode a GIF's first frame — no
// bundled GIF library exists in this app, and this feature is this
// codebase's first need for one, so a small CGImageSource-based decoder is
// added here rather than reaching for a new third-party dependency for one
// view.
struct AnimatedGIFView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        loadAndAnimate(into: imageView)
        return imageView
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {}

    private func loadAndAnimate(into imageView: UIImageView) {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }
            let count = CGImageSourceGetCount(source)
            guard count > 0 else { return }
            var images: [UIImage] = []
            var duration: Double = 0
            for i in 0..<count {
                guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
                images.append(UIImage(cgImage: cgImage))
                duration += Self.frameDuration(source: source, index: i)
            }
            DispatchQueue.main.async {
                if images.count > 1 {
                    imageView.animationImages = images
                    imageView.animationDuration = duration > 0 ? duration : 1.0
                    imageView.startAnimating()
                } else {
                    imageView.image = images.first
                }
            }
        }.resume()
    }

    private static func frameDuration(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let delay = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            ?? gifProperties[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
        return max(delay, 0.02)
    }
}

// ── Per-kind attachment rendering inside the existing message bubble (design gate §4) ──
struct AttachmentContentView: View {
    let message:      FSMessage
    let localPreview: LocalAttachmentPreview?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPlayingVideo = false
    @State private var gifTapped = false

    private let maxWidth:  CGFloat = 240
    private let maxHeight: CGFloat = 280

    var body: some View {
        // compile-errors #3 (20260904-frontend-arch-sweep): switches on the
        // actual FSAttachmentKind enum (exhaustive, no default:) instead of
        // the raw wire string -- see FSMessage.attachmentKindEnum.
        if let kind = message.attachmentKindEnum {
            switch kind {
            case .image: imageContent
            case .video: videoContent
            case .gif:   gifContent
            case .file:  fileContent
            }
        } else {
            EmptyView()
        }
    }

    private var remoteURL: URL? { message.attachmentURL.flatMap(URL.init(string:)) }
    private var senderLabel: String { message.mine ? "You" : (message.sender.isEmpty ? "Them" : message.sender) }

    @ViewBuilder
    private var imageContent: some View {
        Group {
            if let local = localPreview?.image {
                Image(uiImage: local).resizable().aspectRatio(contentMode: .fit)
            } else if let url = remoteURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else if phase.error != nil {
                        unavailablePlaceholder(label: "Image unavailable")
                    } else {
                        loadingPlaceholder
                    }
                }
            } else {
                unavailablePlaceholder(label: "Image unavailable")
            }
        }
        .frame(maxWidth: maxWidth, maxHeight: maxHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLG))
        .accessibilityLabel("\(senderLabel): photo attachment")
    }

    @ViewBuilder
    private var videoContent: some View {
        ZStack {
            if isPlayingVideo, let url = localPreview?.videoURL ?? remoteURL {
                VideoPlayer(player: AVPlayer(url: url))
            } else {
                Rectangle().fill(Color.black.opacity(0.45))
                Button {
                    isPlayingVideo = true
                } label: {
                    ZStack {
                        Circle().fill(Theme.gold.opacity(0.85)).frame(width: 44, height: 44)
                        Image(systemName: "play.fill").foregroundColor(Theme.ink)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: maxWidth, maxHeight: maxHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLG))
        .accessibilityLabel("\(senderLabel): video attachment, tap to play")
    }

    @ViewBuilder
    private var gifContent: some View {
        let playableURLString = message.attachmentMeta?.url ?? message.attachmentURL
        Group {
            if let playableURLString, let playableURL = URL(string: playableURLString) {
                // The one place reduced-motion changes default behavior, not
                // just disables a decorative transition (design gate §4/§6).
                if reduceMotion && !gifTapped {
                    let previewURLString = message.attachmentMeta?.previewUrl ?? playableURLString
                    Button { gifTapped = true } label: {
                        ZStack {
                            AsyncImage(url: URL(string: previewURLString)) { phase in
                                if let image = phase.image { image.resizable().aspectRatio(contentMode: .fit) }
                                else { loadingPlaceholder }
                            }
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(Theme.gold.opacity(0.85))
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    AnimatedGIFView(url: playableURL)
                }
            } else {
                unavailablePlaceholder(label: "Image unavailable")
            }
        }
        .frame(maxWidth: maxWidth, maxHeight: maxHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLG))
        .accessibilityLabel("\(senderLabel): GIF attachment")
    }

    private var fileContent: some View {
        let filename = message.attachmentMeta?.filename ?? "File"
        return Button {
            if let url = remoteURL { UIApplication.shared.open(url) }
        } label: {
            HStack(spacing: Theme.spacingSM) {
                Image(systemName: "doc.fill").foregroundColor(Theme.gold)
                Text(filename)
                    .font(.inter(Theme.fontBody))
                    .foregroundColor(Theme.parchment)
                    .lineLimit(1)
                Spacer(minLength: Theme.spacingSM)
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(Theme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(senderLabel): file attachment, \(filename), double tap to download")
    }

    private var loadingPlaceholder: some View {
        ZStack {
            Rectangle().fill(Theme.gold.opacity(0.12))
            ProgressView().tint(Theme.gold)
        }
    }

    private func unavailablePlaceholder(label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "photo").foregroundColor(Theme.textSecondary)
            Text(label).font(.inter(Theme.fontXXS)).foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(Theme.gold.opacity(0.06))
    }
}
