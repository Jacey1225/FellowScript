// AttachmentLightboxTests.swift — testing gate coverage for task
// 20260905-attachment-lightbox, step 4 (iOS testing).
//
// Covers the acceptance criteria for the new tap-to-expand lightbox added to
// `AttachmentContentView`'s `imageContent`/`gifContent` in
// FellowScript/FellowScript/Chat/MessageAttachments.swift (frontend step 2):
// tap-to-open on image/GIF, blurred backdrop, dismiss gestures, GIF
// playback continuity/restart, reduced-motion fallback, and that
// video/file/existing-GIF-reduced-motion behaviors are unaffected.
//
// Two ViewInspector limitations shape this file's structure, both already
// established precedent elsewhere in this test target:
//
//   1. `AttachmentLightboxView` (the actual lightbox view, holding the
//      backdrop/motion/dismiss/close-button implementation) is declared
//      `private` to MessageAttachments.swift. Like `ContinueIslandButtonStyle`
//      (see NoteResumeCardContinueIslandTests.swift's file header), a
//      `private` type stays file-scoped even under `@testable import` — it
//      cannot be constructed or inspected directly from this file.
//   2. Even if it weren't private, ViewInspector's own guide (guide_popups.md,
//      "System popup views") states plainly that native `.sheet`/
//      `.fullScreenCover` "cannot be inspected as-is" without adding a
//      bespoke Inspectable wrapper modifier to the main target — which this
//      task's design/frontend gates never called for, and isn't this testing
//      gate's place to retrofit into shipped production code.
//
// So this file is split in two:
//   A. `AttachmentLightboxTapWiringTests` — real ViewInspector behavioral
//      coverage of everything that *is* reachable: `AttachmentContentView`
//      is `internal`, and its `imageContent`/`gifContent`/`videoContent`/
//      `fileContent` branches, tap gestures, and accessibility labels are
//      all real rendered output, not private internals. This proves the tap
//      targets exist and are wired without crashing, and that the
//      pre-existing GIF reduced-motion tap-to-play / video tap-to-play /
//      file-download affordances are untouched by this task.
//   B. `AttachmentLightboxSourcePinnedTests` — reads the real shipped
//      MessageAttachments.swift source (the same technique this target
//      already established in NoteResumeCardContinueIslandTests.swift and
//      ChatScheduleUICleanupIOSRegressionTests.swift for facts ViewInspector
//      can't cheaply assert on) to pin AttachmentLightboxView's own
//      unreachable implementation: backdrop material, dismiss mechanisms,
//      entry/exit motion timings, the reduced-motion "skip, don't shorten"
//      fallback, GIF restart-from-frame-0, the 44x44 scrimmed close button,
//      and that no caption/sender label is duplicated in the overlay.

import XCTest
import SwiftUI
import ViewInspector
@testable import FellowScript

// MARK: - A. Tap wiring (real ViewInspector behavioral coverage)

final class AttachmentLightboxTapWiringTests: XCTestCase {

    private func message(
        sender: String = "priya", mine: Bool = false,
        attachmentKind: String?, attachmentURL: String? = nil, attachmentMeta: FSAttachmentMeta? = nil
    ) -> FSMessage {
        var m = FSMessage(id: "m1", text: "", mine: mine, sender: sender, timestamp: "2026-09-05T12:00:00.000Z")
        m.attachmentKind = attachmentKind
        m.attachmentURL  = attachmentURL
        m.attachmentMeta = attachmentMeta
        return m
    }

    // Type-erased (ViewType.ClassifiedView, not ViewType.Group specifically):
    // imageContent/gifContent/fileContent each carry their accessibility
    // label on an outer Group, but videoContent carries its own directly on
    // a ZStack -- one finder that matches by label regardless of the
    // concrete container type covers all four branches.
    private func findLabeled<V: View>(_ sut: V, label: String) throws -> InspectableView<ViewType.ClassifiedView> {
        try sut.inspect().find(where: { v in
            (try? v.accessibilityLabel().string()) == label
        })
    }

    // ── Image: tap-to-expand wired for every source state ──────────────────

    func test_imageAttachment_withRemoteURL_tapDoesNotThrow() throws {
        let msg = message(attachmentKind: "image", attachmentURL: "https://example.com/photo.jpg")
        let sut = AttachmentContentView(message: msg, localPreview: nil)
        let group = try findLabeled(sut, label: "priya: photo attachment")
        XCTAssertNoThrow(try group.callOnTapGesture(),
                          "tapping a remote-URL image attachment must open the lightbox without crashing")
    }

    func test_imageAttachment_withLocalPreview_tapDoesNotThrow() throws {
        let msg = message(attachmentKind: "image")
        let sut = AttachmentContentView(message: msg, localPreview: LocalAttachmentPreview(image: UIImage()))
        let group = try findLabeled(sut, label: "priya: photo attachment")
        XCTAssertNoThrow(try group.callOnTapGesture(),
                          "tapping a local-preview (optimistic echo) image attachment must open the lightbox without crashing")
    }

    func test_imageAttachment_noDisplayableSource_tapDoesNotThrow() throws {
        // Neither a local preview nor a remote URL -- the unavailablePlaceholder
        // branch. The tap gesture is still attached (one shared gesture
        // regardless of branch); it must simply no-op internally rather than
        // throw, since there is nothing to expand into.
        let msg = message(attachmentKind: "image")
        let sut = AttachmentContentView(message: msg, localPreview: nil)
        let group = try findLabeled(sut, label: "priya: photo attachment")
        XCTAssertNoThrow(try group.callOnTapGesture())
    }

    // ── GIF: tap-to-expand wired once actually playing, motion allowed ──────

    // Not overridden: this simulator/test-host's default @Environment
    // (\.accessibilityReduceMotion) is false (system Reduce Motion off), so
    // gifContent's `reduceMotion && !gifTapped` gate is false and the
    // already-playing AnimatedGIFView branch renders directly -- exactly the
    // "motion allowed" case. (A direct environment override was tried and
    // dropped: on this project's current SDK, `EnvironmentValues.
    // accessibilityReduceMotion` is a get-only property -- `\.
    // accessibilityReduceMotion` isn't even a WritableKeyPath anymore, so it
    // can't be force-set via `.environment(_:_:)`/`.transformEnvironment` in
    // a test. The reduced-motion-specific branch is covered by
    // AttachmentLightboxSourcePinnedTests instead, below.)
    func test_gifAttachment_motionAllowed_rendersAnimatedGIFViewWithTapGesture() throws {
        let msg = message(attachmentKind: "gif", attachmentMeta: FSAttachmentMeta(url: "https://example.com/a.gif"))
        let sut = AttachmentContentView(message: msg, localPreview: nil)
        let group = try findLabeled(sut, label: "priya: GIF attachment")
        let gifView = try group.find(AnimatedGIFView.self)
        XCTAssertNoThrow(try gifView.callOnTapGesture(),
                          "tapping an already-playing GIF (motion allowed, so it autoplays inline immediately) must open the lightbox without crashing")
    }

    // ── Video: tap-to-play affordance unaffected (out of scope for the
    // lightbox per intake-spec.md's explicit exclusion) ─────────────────────

    func test_videoAttachment_playButton_stillPresentAndTappable() throws {
        let msg = message(attachmentKind: "video", attachmentURL: "https://example.com/clip.mp4")
        let sut = AttachmentContentView(message: msg, localPreview: nil)
        let group = try findLabeled(sut, label: "priya: video attachment, tap to play")
        let playButton = try group.find(ViewType.Button.self)
        XCTAssertNoThrow(try playButton.tap(),
                          "video's own inline tap-to-play must be untouched by the image/GIF lightbox work")
    }

    // ── File: download affordance unaffected ────────────────────────────────

    func test_fileAttachment_downloadButton_stillPresent() throws {
        // Doesn't actually tap this button: its action calls
        // UIApplication.shared.open(url), a real system side effect this
        // unit test target has no precedent for invoking. Structural
        // presence here, plus the source-pinned "fileContent never
        // references isLightboxPresented" check below, together cover the
        // "file download unaffected" acceptance criterion without that risk.
        let msg = message(attachmentKind: "file", attachmentURL: "https://example.com/report.pdf",
                           attachmentMeta: FSAttachmentMeta(filename: "report.pdf"))
        let sut = AttachmentContentView(message: msg, localPreview: nil)
        XCTAssertNoThrow(try sut.inspect().find(ViewType.Button.self, where: { b in
            (try? b.accessibilityLabel().string())?.contains("file attachment") ?? false
        }), "file attachments must keep rendering their own download button, untouched by the image/GIF lightbox work")
    }
}

// MARK: - B. Source-pinned AttachmentLightboxView implementation details

final class AttachmentLightboxSourcePinnedTests: XCTestCase {

    /// Reads the real shipped MessageAttachments.swift source -- the
    /// established technique in this target (NoteResumeCardContinueIslandTests,
    /// ChatScheduleUICleanupIOSRegressionTests) for pinning facts a `private`
    /// type or a ViewInspector-unsupported native modifier (here, both at
    /// once) puts out of reach of live inspection.
    private func attachmentsSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent("FellowScript/Chat/MessageAttachments.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Just the `AttachmentLightboxView` struct body, isolated so assertions
    /// about it can't accidentally pass by matching unrelated code elsewhere
    /// in this large file.
    private func lightboxViewSource() throws -> String {
        let source = try attachmentsSource()
        guard let start = source.range(of: "private struct AttachmentLightboxView: View {") else {
            XCTFail("AttachmentLightboxView not found in MessageAttachments.swift")
            return ""
        }
        return String(source[start.lowerBound...])
    }

    // ── Wired via fullScreenCover, one shared viewer for both call sites ────

    func test_attachmentContentView_presentsLightboxViaFullScreenCover() throws {
        let source = try attachmentsSource()
        XCTAssertTrue(
            source.contains(".fullScreenCover(isPresented: $isLightboxPresented) {") &&
            source.contains("AttachmentLightboxView("),
            "AttachmentContentView must present AttachmentLightboxView via .fullScreenCover(isPresented:) -- the full/near-full-screen presentation the acceptance criteria require"
        )
    }

    func test_imageContent_and_gifContent_bothSetIsLightboxPresentedOnTap() throws {
        let source = try attachmentsSource()
        guard let imageRange = source.range(of: "private var imageContent: some View {"),
              let gifRange = source.range(of: "private var gifContent: some View {") else {
            return XCTFail("imageContent/gifContent not found")
        }
        let imageBody = String(source[imageRange.upperBound...].prefix(2200))
        let gifBody = String(source[gifRange.upperBound...].prefix(2200))
        XCTAssertTrue(imageBody.contains("isLightboxPresented = true"),
                      "imageContent's tap gesture must set isLightboxPresented")
        XCTAssertTrue(gifBody.contains("isLightboxPresented = true"),
                      "gifContent's tap gesture (on the already-playing AnimatedGIFView branch) must set isLightboxPresented")
    }

    // ── Backdrop: blur/dim treatment (acceptance criterion) ─────────────────

    func test_backdrop_usesMaterialPlusTintDoctrine_notANewBlurRecipe() throws {
        let body = try lightboxViewSource()
        XCTAssertTrue(body.contains(".fill(.ultraThinMaterial)"),
                      "the backdrop must use the system material, same doctrine as DashboardComponents.swift's glassCard")
        XCTAssertTrue(body.contains("Theme.ink.opacity(0.93)"),
                      "the backdrop must layer the app's near-opaque dark tint over the material so it reads as 'the chat is gone, replaced by a frosted dark surface'")
    }

    // ── Dismiss gestures: tap-anywhere (backdrop or media) + close button ───

    func test_dismiss_tapAnywhereOnZStackDismisses() throws {
        let body = try lightboxViewSource()
        XCTAssertTrue(
            body.contains(".onTapGesture { dismiss() }"),
            "a single tap gesture over the whole presentation (backdrop and media alike, since there is no separate tap handler carving out the media area) must call dismiss()"
        )
    }

    func test_dismiss_closeButtonExists_44x44_withScrimForContrast() throws {
        let body = try lightboxViewSource()
        XCTAssertTrue(body.contains("Button(action: dismiss)"),
                      "an explicit close (X) button must exist for discoverability, per design gate §1")
        XCTAssertTrue(body.contains(".frame(width: 44, height: 44)"),
                      "the close button must meet the 44x44pt minimum tap target")
        XCTAssertTrue(
            body.contains("Circle().fill(Color.black.opacity(0.3))") && body.contains("Theme.parchment"),
            "the close glyph must sit on its own dark scrim (not Theme.textSecondary) so AA contrast holds regardless of what's behind the blur -- design gate §8 / Q14"
        )
        XCTAssertTrue(body.contains(#"accessibilityLabel("Close")"#),
                      "the close button must carry an explicit 'Close' accessibility label")
    }

    // ── Entry/exit motion: tuned easing, exit faster than enter (Q9) ────────

    func test_entryMotion_easeOut300ms() throws {
        let body = try lightboxViewSource()
        XCTAssertTrue(body.contains("withAnimation(.easeOut(duration: 0.3)) { isExpanded = true }"),
                      "entry motion must be .easeOut over 300ms")
    }

    func test_exitMotion_easeInOut220ms_fasterThanEntry() throws {
        let body = try lightboxViewSource()
        XCTAssertTrue(body.contains("withAnimation(.easeInOut(duration: 0.22)) { isExpanded = false }"),
                      "exit motion must be .easeInOut over 220ms -- faster than the 300ms entry, per design gate §6's 'exit faster than enter'")
    }

    // ── Reduced motion: skip outright, not shortened (this codebase's own
    // established Theme.swift doctrine, carried into this new view) ────────

    func test_reducedMotion_entrySkipsAnimationOutright() throws {
        let body = try lightboxViewSource()
        XCTAssertTrue(
            body.contains("if reduceMotion {\n                isExpanded = true\n            } else {"),
            "under Reduce Motion, the media must appear at full scale/opacity immediately (isExpanded = true with no withAnimation wrapper) rather than merely playing a shortened version of the entry animation"
        )
    }

    func test_reducedMotion_dismissSkipsAnimationOutright() throws {
        let body = try lightboxViewSource()
        XCTAssertTrue(
            body.contains("guard !reduceMotion else {\n            onDismiss()\n            return\n        }"),
            "under Reduce Motion, dismiss() must call onDismiss immediately, skipping the exit withAnimation entirely"
        )
    }

    func test_showsExpanded_derivesFromEitherManualStateOrReduceMotion() throws {
        let body = try lightboxViewSource()
        XCTAssertTrue(body.contains("private var showsExpanded: Bool { isExpanded || reduceMotion }"),
                      "the media's scale/opacity must resolve to fully shown whenever Reduce Motion is on, regardless of the isExpanded animation state")
    }

    // ── GIF playback continuity: restart from frame 0, fresh instance ───────

    func test_gifCase_mountsFreshAnimatedGIFView_forRestartFromFrameZero() throws {
        let body = try lightboxViewSource()
        guard let mediaRange = body.range(of: "private var media: some View {") else {
            return XCTFail("media computed property not found in AttachmentLightboxView")
        }
        let mediaBody = String(body[mediaRange.upperBound...].prefix(2200))
        XCTAssertTrue(mediaBody.contains("case .gif(let url):"))
        XCTAssertTrue(mediaBody.contains("AnimatedGIFView(url: url)"),
                      "the lightbox's GIF case must mount its own fresh AnimatedGIFView instance -- restarting from frame 0 rather than sharing decoded state/phase with the inline renderer (design gate §3)")
    }

    // ── No caption/sender-label duplication in the overlay (design gate §4) ─

    func test_lightbox_neverRendersSenderLabelAsVisibleText() throws {
        let body = try lightboxViewSource()
        // senderLabel is only ever used inside accessibilityLabel(...) calls
        // in this view -- never as a standalone Text(senderLabel).
        XCTAssertFalse(body.contains("Text(senderLabel)"),
                       "the lightbox must not render a visible caption/sender label -- it shows only the media itself, per design gate §4 / Q11")
        XCTAssertTrue(body.contains("senderLabel): photo attachment, expanded") ||
                      body.contains("senderLabel): GIF attachment, expanded"),
                      "senderLabel should still back the accessibility label of the expanded media, just not a visible Text node")
    }

    // ── Loading state: plain spinner, no bespoke treatment (Q17) ────────────

    func test_remoteImageLoadingState_isPlainProgressView() throws {
        let body = try lightboxViewSource()
        XCTAssertTrue(body.contains("ProgressView().tint(Theme.gold)"),
                      "the expanded view's own load state (for a remote image not already locally cached) must be a plain spinner, no custom/expressive loading treatment invented for this")
    }

    // ── GIF reduced-motion tap-to-play gate: unaffected, and the lightbox
    // trigger must sit on the already-playing branch only (design gate §3).
    // Source-pinned rather than live-inspected: this SDK's
    // EnvironmentValues.accessibilityReduceMotion is a get-only property, so
    // `\.accessibilityReduceMotion` isn't a WritableKeyPath and can't be
    // force-set via `.environment(_:_:)` in a test -- confirmed empirically
    // (both `.environment(\.accessibilityReduceMotion, _)` and
    // `.transformEnvironment(\.self) { $0.accessibilityReduceMotion = _ }`
    // fail to compile against this project's current SDK). ─────────────────

    func test_gifContent_reducedMotionGateOnlyAffectsUntappedPlayButtonBranch() throws {
        let source = try attachmentsSource()
        guard let gifRange = source.range(of: "private var gifContent: some View {") else {
            return XCTFail("gifContent not found")
        }
        let gifBody = String(source[gifRange.upperBound...].prefix(2200))

        XCTAssertTrue(gifBody.contains("if reduceMotion && !gifTapped {"),
                      "the reduced-motion tap-to-play button must remain gated on `reduceMotion && !gifTapped`, unchanged by this task")
        // The lightbox tap must be attached to the `else` branch (the
        // already-playing AnimatedGIFView), never to the reduced-motion
        // Button itself -- i.e. exactly one `isLightboxPresented = true`
        // in this function, and it must come after the reduced-motion
        // Button's own closing brace, not inside it.
        guard let gateRange = gifBody.range(of: "if reduceMotion && !gifTapped {"),
              let lightboxRange = gifBody.range(of: "isLightboxPresented = true") else {
            return XCTFail("expected both the reduced-motion gate and the lightbox trigger inside gifContent")
        }
        XCTAssertTrue(lightboxRange.lowerBound > gateRange.upperBound,
                      "isLightboxPresented must be set from the already-playing AnimatedGIFView branch (after the reduced-motion gate's Button), not from the reduced-motion tap-to-play Button itself")
        XCTAssertTrue(gifBody.contains("gifTapped = true }"),
                      "the reduced-motion Button's own action must remain `gifTapped = true` only -- it must not also flip isLightboxPresented")
    }

    // ── videoContent / fileContent stay untouched by this task ──────────────

    func test_videoContentAndFileContent_neverReferenceLightboxState() throws {
        let source = try attachmentsSource()
        guard let videoRange = source.range(of: "private var videoContent: some View {"),
              let fileRangeStart = source.range(of: "private var fileContent: some View {") else {
            return XCTFail("videoContent/fileContent not found")
        }
        let videoBody = String(source[videoRange.upperBound...].prefix(900))
        let fileBody = String(source[fileRangeStart.upperBound...].prefix(900))
        XCTAssertFalse(videoBody.contains("isLightboxPresented"),
                       "videoContent must remain untouched -- video attachments are explicitly out of scope for this task")
        XCTAssertFalse(fileBody.contains("isLightboxPresented"),
                       "fileContent must remain untouched -- files already open externally and are not a lightbox candidate")
    }
}
