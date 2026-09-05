// MessageAttachmentsPickerFailureTests.swift — regression coverage for task
// 20260904-compliance-error-handling-consistency (dependency-errors #6):
// PhotoVideoPicker/DocumentPicker's coordinators previously called
// `onPicked(nil)` identically for a plain user cancellation and for a
// genuine failure (copy/decode error, unsupported item, security-scope
// failure), so ChatThreadView.handlePicked's `guard let attachment else {
// return }` silently no-op'd on both -- a picker failure vanished with no
// user-facing signal at all. Both coordinators now also call a dedicated
// `onFailure` closure on the genuine-failure branches only, never on an
// unambiguous cancellation.
//
// Exercises the real Coordinator delegate methods directly (no UIKit
// picker presentation needed) -- these are plain NSObject delegate
// conformances, callable synchronously/async exactly as UIKit would invoke
// them.

import XCTest
import UniformTypeIdentifiers
import PhotosUI
@testable import FellowScript

final class MessageAttachmentsPickerFailureTests: XCTestCase {

    // Previously this file retained every StagedAttachment constructed
    // during a test for the process's lifetime (never deallocating one),
    // to dodge a then-unfixed crash in StagedAttachment's deinit path on
    // an iOS 18.5 destination (task 20260904-compliance-error-handling-
    // consistency). That crash's root cause and fix are now both
    // confirmed (task 20260905-stagedattachment-deinit-crash --
    // `nonisolated deinit {}` added to StagedAttachment), so the
    // permanent-retain workaround is gone; see
    // `test_stagedAttachment_constructAndDeallocate_doesNotCrash` below,
    // which exercises the real deinit path directly instead of avoiding it.

    // MARK: - DocumentPicker

    func test_documentPicker_cancelled_callsOnPickedNil_neverOnFailure() {
        var pickedCalls = 0
        var pickedValue: StagedAttachment??
        var failureCalls = 0
        let coordinator = DocumentPicker.Coordinator(
            onPicked: { attachment in pickedCalls += 1; pickedValue = attachment },
            onFailure: { failureCalls += 1 }
        )

        coordinator.documentPickerWasCancelled(UIDocumentPickerViewController(forOpeningContentTypes: [.pdf]))

        XCTAssertEqual(pickedCalls, 1)
        XCTAssertNil(pickedValue ?? nil)
        XCTAssertEqual(failureCalls, 0, "a plain cancellation must never fire onFailure")
    }

    func test_documentPicker_emptyURLs_callsOnPickedNil_andOnFailure() {
        var pickedCalls = 0
        var failureCalls = 0
        let coordinator = DocumentPicker.Coordinator(
            onPicked: { _ in pickedCalls += 1 },
            onFailure: { failureCalls += 1 }
        )

        coordinator.documentPicker(UIDocumentPickerViewController(forOpeningContentTypes: [.pdf]), didPickDocumentsAt: [])

        XCTAssertEqual(pickedCalls, 1)
        XCTAssertEqual(failureCalls, 1, "an empty URL list from didPickDocumentsAt is a genuine failure, not a cancellation")
    }

    func test_documentPicker_unreadableFile_callsOnPickedNil_andOnFailure() {
        var pickedValue: StagedAttachment??
        var failureCalls = 0
        let coordinator = DocumentPicker.Coordinator(
            onPicked: { attachment in pickedValue = attachment },
            onFailure: { failureCalls += 1 }
        )

        // A URL to a file that doesn't exist -- security-scope access still
        // "succeeds" trivially for a non-security-scoped local URL, but
        // Data(contentsOf:) must fail, hitting the genuine-failure branch.
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-test-missing-\(UUID().uuidString).pdf")

        coordinator.documentPicker(UIDocumentPickerViewController(forOpeningContentTypes: [.pdf]), didPickDocumentsAt: [missingURL])

        XCTAssertNil(pickedValue ?? nil)
        XCTAssertEqual(failureCalls, 1, "a file that can't be read must surface onFailure, not vanish silently")
    }

    func test_documentPicker_validFile_callsOnPicked_withAttachment_neverOnFailure() {
        var pickedValue: StagedAttachment??
        var failureCalls = 0
        let coordinator = DocumentPicker.Coordinator(
            onPicked: { attachment in pickedValue = attachment },
            onFailure: { failureCalls += 1 }
        )

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs-test-doc-\(UUID().uuidString).txt")
        try! "hello world".data(using: .utf8)!.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        coordinator.documentPicker(UIDocumentPickerViewController(forOpeningContentTypes: [.plainText]), didPickDocumentsAt: [fileURL])

        XCTAssertNotNil(pickedValue ?? nil, "a genuinely readable file must produce a StagedAttachment")
        XCTAssertEqual(pickedValue??.kind, .file)
        XCTAssertEqual(failureCalls, 0, "a successful pick must never fire onFailure")
        // Let `attachment`/`pickedValue` fall out of scope and deallocate
        // normally at the end of this test -- see
        // test_stagedAttachment_constructAndDeallocate_doesNotCrash for the
        // dedicated regression coverage of that deinit path.
    }

    // MARK: - StagedAttachment deinit regression
    // (task 20260905-stagedattachment-deinit-crash)

    // Real regression test, not a workaround: constructs a StagedAttachment
    // and lets it deallocate for real, proving the fixed deinit path (see
    // `nonisolated deinit` on StagedAttachment in MessageAttachments.swift)
    // no longer crashes. Before that fix, this exact construct-then-release
    // pattern reliably crashed with a malloc
    // pointer-being-freed-was-not-allocated abort on an iOS 18.5
    // destination (FellowScript-Test-iOS18) -- reproduced via
    // `swift_task_deinitOnExecutorMainActorBackDeploy` in
    // StagedAttachment's synthesized deinit -- while passing cleanly on an
    // iOS 26.5 destination, which is why this must be run on both
    // destinations to be meaningful: passing only proves the iOS 26.5 case,
    // which was never broken.
    func test_stagedAttachment_constructAndDeallocate_doesNotCrash() {
        var attachment: StagedAttachment? = StagedAttachment(kind: .file, fileName: "regression.txt")
        XCTAssertNotNil(attachment)
        attachment = nil
        // Reaching this line without a SIGABRT is the assertion: the prior
        // bug crashed the whole test process inside deinit, so there is no
        // in-process value to assert on beyond "execution continued."
        XCTAssertNil(attachment)
    }

    // MARK: - PhotoVideoPicker

    func test_photoVideoPicker_emptyResults_callsOnPickedNil_neverOnFailure() {
        var pickedCalls = 0
        var failureCalls = 0
        let coordinator = PhotoVideoPicker.Coordinator(
            onPicked: { _ in pickedCalls += 1 },
            onFailure: { failureCalls += 1 }
        )

        let picker = PHPickerViewController(configuration: PHPickerConfiguration())
        coordinator.picker(picker, didFinishPicking: [])

        XCTAssertEqual(pickedCalls, 1)
        XCTAssertEqual(failureCalls, 0, "no item selected is a plain cancellation, not a failure")
    }

    // NOTE: the "unsupported item type slips through the filter" and
    // "movie/image load genuinely fails" branches (also wired to
    // onFailure) aren't exercised here -- PHPickerResult has no accessible
    // public initializer in this SDK, so a real PHPickerResult can't be
    // constructed from a test target at all. The empty-results (plain
    // cancellation) path above is the only PhotoVideoPicker.Coordinator
    // branch reachable without UIKit picker presentation; the remaining
    // branches were verified by code review only (see frontend gate's
    // summary and the diff itself) -- flagged here rather than silently
    // omitted, matching this task's own "no silent gaps" standard.
}
