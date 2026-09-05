// NetworkServiceSharedEncoderDecoderRegressionTests.swift — testing-gate
// coverage for task 20260904-compliance-performance-fixes, step 2 (Low
// optimization #6): NetworkService.swift previously allocated a fresh
// JSONEncoder()/JSONDecoder() on every single request()/decode() call — the
// app's single busiest service. Both are now hoisted to shared, private
// instances (sharedEncoder/sharedDecoder) declared once at the top of the
// class, mirroring DiskCache.swift's existing hoisted-instance pattern.
//
// Apple documents both types as safe for concurrent encode/decode calls (no
// per-call mutable state that could leak between calls), so this hoist
// should behave identically to fresh-per-call instances. This file proves
// that directly against the real NetworkService.shared singleton (not a
// reimplementation) via requestAttachmentUploadURL — the one call site that
// round-trips through BOTH the shared encoder (its Encodable request body)
// and the shared decoder (its FSUploadURLInfo response) together.
//
// Uses the same StubURLProtocol harness as
// NetworkServiceFetchBookmarksDecodeFailureBeaconTests.swift /
// NetworkServiceGetErrorHandlingTests.swift.
import XCTest
@testable import FellowScript

final class NetworkServiceSharedEncoderDecoderRegressionTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    override func setUp() async throws {
        try await super.setUp()
        // Same drain window as this harness's other users (e.g.
        // NetworkServiceFetchBookmarksDecodeFailureBeaconTests) -- this test
        // target may run alongside another concurrently-invoked xcodebuild
        // test suite sharing the same simulator.
        try await Task.sleep(nanoseconds: 700_000_000)
        StubURLProtocol.resetRequestLog()
    }

    private func stubUploadInfoBody(objectKey: String) -> Data {
        #"{"url": "https://s3.example.com/\#(objectKey)", "fields": {"key": "\#(objectKey)"}, "object_key": "\#(objectKey)", "expires_in": 900}"#
            .data(using: .utf8)!
    }

    // MARK: - Sequential reuse: many different shapes back-to-back through
    // the same shared instances must never bleed state between calls.

    func test_sharedEncoderDecoder_sequentialCallsWithDifferentPayloads_eachRoundTripsCorrectly() async throws {
        StubURLProtocol.stubStatusCode = 200

        let cases: [(kind: String, contentType: String, size: Int?, objectKey: String)] = [
            ("image", "image/png",       12345,  "obj-image-1"),
            ("video", "video/mp4",       999999, "obj-video-2"),
            ("file",  "application/pdf", nil,    "obj-file-3"),
        ]

        for c in cases {
            StubURLProtocol.stubBody = stubUploadInfoBody(objectKey: c.objectKey)
            let info = try await NetworkService.shared.requestAttachmentUploadURL(
                userId: "user-1", attachmentKind: c.kind, contentType: c.contentType, sizeBytes: c.size)

            XCTAssertEqual(info.object_key, c.objectKey,
                           "sharedDecoder must decode each distinct response correctly with no residual state from the previous call")

            let sentBody = StubURLProtocol.requestLog.last?.bodyJSON
            XCTAssertEqual(sentBody?["attachment_kind"] as? String, c.kind,
                           "sharedEncoder must encode each distinct request body correctly with no residual state from the previous call")
            XCTAssertEqual(sentBody?["content_type"] as? String, c.contentType)
            if let size = c.size {
                XCTAssertEqual(sentBody?["size_bytes"] as? Int, size)
            } else {
                XCTAssertNil(sentBody?["size_bytes"],
                             "a nil sizeBytes must still encode as a genuinely absent/null field, not leak a previous call's numeric value")
            }
        }
    }

    // MARK: - Concurrency: multiple simultaneous calls through the same
    // singleton (and therefore the same shared encoder/decoder instances)
    // must not corrupt one another's result -- the whole premise of hoisting
    // these to shared instances is that they're documented safe for exactly
    // this kind of concurrent use.

    func test_sharedEncoderDecoder_concurrentCalls_allDecodeCorrectlyWithNoCorruption() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = stubUploadInfoBody(objectKey: "obj-concurrent")

        let results = try await withThrowingTaskGroup(of: FSUploadURLInfo.self) { group in
            for i in 0..<10 {
                group.addTask {
                    try await NetworkService.shared.requestAttachmentUploadURL(
                        userId: "user-\(i)", attachmentKind: "image", contentType: "image/png", sizeBytes: i)
                }
            }
            var collected: [FSUploadURLInfo] = []
            for try await result in group { collected.append(result) }
            return collected
        }

        XCTAssertEqual(results.count, 10)
        for info in results {
            XCTAssertEqual(info.object_key, "obj-concurrent",
                           "every concurrent call must decode the correct value -- a corrupted shared decoder would show garbled/mismatched fields under concurrent access")
        }
    }

    // MARK: - Source guard: no stray per-call JSONEncoder()/JSONDecoder()
    // allocation crept back in anywhere in NetworkService.swift (the fix's
    // own stated goal) -- only the two hoisted declarations should remain.

    func test_source_networkService_noPerCallEncoderOrDecoderAllocationsRemain() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let file = thisFile
            .deletingLastPathComponent()          // FellowScriptTests/
            .deletingLastPathComponent()          // FellowScript/ (repo-relative project root)
            .appendingPathComponent("FellowScript/Services/NetworkService.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        let codeLines = source.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
        }
        let encoderAllocationLines = codeLines.filter { $0.contains("JSONEncoder()") }
        let decoderAllocationLines = codeLines.filter { $0.contains("JSONDecoder()") }

        XCTAssertEqual(encoderAllocationLines.count, 1,
                       "expected exactly one non-comment JSONEncoder() allocation in the whole file -- the hoisted `private let sharedEncoder` declaration; anything more means a per-call allocation crept back in")
        XCTAssertEqual(decoderAllocationLines.count, 1,
                       "expected exactly one non-comment JSONDecoder() allocation in the whole file -- the hoisted `private let sharedDecoder` declaration; anything more means a per-call allocation crept back in")
    }
}
