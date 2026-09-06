// GifPickerGridPolishTests.swift — coverage for task
// 20260905-gif-picker-grid-polish (testing step 4, the final gate)'s iOS-side
// changes to MessageAttachments.swift: GifSearchSheet's grid cells moved from
// a native-aspect-ratio AsyncImage (the direct cause of the reported ragged
// grid) to a fixed 1:1 GifPickerCell backed by AnimatedGIFView, which now
// gained a `contentMode`/`onFirstFrame` hook plus a `dismantleUIView`-driven
// task-cancellation lifecycle for scrolling LazyVGrid performance (design
// gate §4's "cancel rather than build a bespoke visibility tracker").
//
// GifPickerCell/GifSearchSheet themselves are plain SwiftUI Views with no
// injectable seams and no UIViewRepresentableContext construction available
// outside a real SwiftUI render pass -- consistent with this codebase's
// existing precedent (GifPickerDefaultBrowseViewModelTests exercises the
// ViewModel layer only, never the View layer directly; codegraph confirms
// zero pre-existing tests at the View layer for this sheet). What IS a plain,
// injectable, testable unit here is AnimatedGIFView's own static lifecycle
// method and its Coordinator, which carry the actual regression risk this
// task introduced (a cancellation safeguard that's easy to silently drop in
// a future refactor without any test catching it) -- covered below.
//
// The full-resolution send path (StagedAttachment(kind: .gif, width:,
// height:, gifResult:)) is unchanged by this task (verified by inspection —
// GifSearchSheet.gifCell's onSelect body is byte-identical to before this
// fix) and was already exercised end-to-end by
// GifPickerDefaultBrowseViewModelTests + this project's existing attachment
// staging tests; not re-duplicated here.

import XCTest
@testable import FellowScript

final class GifPickerGridPolishTests: XCTestCase {

    // MARK: - AnimatedGIFView.dismantleUIView (grid-scroll performance safeguard)

    /// Design gate §4 / frontend.json: rather than building a bespoke
    /// visibility-tracking system for a scrolling LazyVGrid with potentially
    /// dozens of concurrent animated-GIF decoders, AnimatedGIFView relies on
    /// SwiftUI tearing down a cell's UIViewRepresentable (via
    /// `dismantleUIView`) once it scrolls far enough off-screen, and cancels
    /// its own in-flight URLSessionDataTask at that point. If this
    /// cancellation were ever silently dropped in a refactor, a fast scroll
    /// through a large browse/search grid would pile up unbounded concurrent
    /// downloads with nothing to bound them -- this test exists to catch
    /// exactly that regression.
    func test_dismantleUIView_cancelsTheCoordinatorsInFlightTask() {
        let coordinator = AnimatedGIFView.Coordinator()
        let url = URL(string: "https://example.com/some-large-reaction.gif")!
        let task = URLSession.shared.dataTask(with: url)
        coordinator.task = task
        let imageView = UIImageView()

        AnimatedGIFView.dismantleUIView(imageView, coordinator: coordinator)

        // A freshly-created (never-resumed) URLSessionDataTask starts
        // `.suspended`; cancelling it moves it directly to `.canceling`
        // (and eventually `.completed`) rather than leaving it `.suspended`
        // or `.running` -- proving `dismantleUIView` actually called
        // `cancel()` on the coordinator's stored task rather than being a
        // no-op.
        XCTAssertNotEqual(task.state, .suspended, "dismantleUIView must actually cancel the in-flight task, not leave it dangling")
        XCTAssertTrue(task.state == .canceling || task.state == .completed,
                      "expected the task to be cancelling/completed after dismantleUIView, got \(task.state)")
    }

    /// A cell that finished loading before being torn down (task already
    /// nil'd out, or never set) must not crash `dismantleUIView` -- this is
    /// the common case for every cell that scrolls off-screen after its GIF
    /// already finished downloading and animating.
    func test_dismantleUIView_withNoStoredTask_doesNotCrash() {
        let coordinator = AnimatedGIFView.Coordinator()
        let imageView = UIImageView()

        AnimatedGIFView.dismantleUIView(imageView, coordinator: coordinator)

        XCTAssertNil(coordinator.task)
    }

    // MARK: - AnimatedGIFView contentMode/onFirstFrame defaults (interface contract)

    /// The grid cell passes `.scaleAspectFill` (crop-fill, matching web's
    /// `object-fit: cover`) plus an `onFirstFrame` callback, while the
    /// pre-existing full-size sent-GIF call site
    /// (AttachmentContentView.gifContent) must keep its original
    /// `.scaleAspectFit` default with no callback -- design gate §4 is
    /// explicit that the existing call site is unchanged. This locks in
    /// AnimatedGIFView's default parameter values so a future edit can't
    /// silently flip the sent-message playback's crop behavior while
    /// wiring up the new grid-cell parameters.
    func test_animatedGIFView_defaultContentMode_isScaleAspectFit_andOnFirstFrame_isNil() {
        let view = AnimatedGIFView(url: URL(string: "https://example.com/a.gif")!)

        XCTAssertEqual(view.contentMode, .scaleAspectFit,
                       "the original sent-GIF full-size playback call site relies on this default staying .scaleAspectFit")
        XCTAssertNil(view.onFirstFrame, "no callback should fire unless a caller (the grid cell) explicitly opts in")
    }

    func test_animatedGIFView_gridCellConfiguration_acceptsScaleAspectFillAndACallback() {
        var fired = false
        let view = AnimatedGIFView(url: URL(string: "https://example.com/a.gif")!,
                                    contentMode: .scaleAspectFill,
                                    onFirstFrame: { fired = true })

        XCTAssertEqual(view.contentMode, .scaleAspectFill)
        view.onFirstFrame?()
        XCTAssertTrue(fired)
    }
}
