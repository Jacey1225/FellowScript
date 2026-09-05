// MessagingAttachmentsNetworkServiceTests.swift — regression/coverage for
// task 20260904-messaging-attachments (testing step 6, final gate).
//
// Covers the new NetworkService surface added for messaging attachments:
//   - requestAttachmentUploadURL: correct path/method/body, decodes
//     FSUploadURLInfo, throws on an error response (not a silent nil).
//   - uploadAttachment: POSTs a multipart/form-data body straight to
//     uploadInfo.url (never this app's own apiBase), carries every one of
//     uploadInfo.fields ahead of the file part, and throws on a non-2xx S3
//     response instead of silently swallowing the failure.
//   - searchGifs: a blank query short-circuits with no network call; a real
//     query hits GET /message/gif-search with the query URL-encoded and
//     unwraps `.results`; a malformed/undecodable response degrades to an
//     empty array rather than throwing or crashing (mirrors this method's
//     documented "rendering hiccup" tolerance, matching
//     backend/interactions/attachments.py's generate_download_url
//     precedent).
//   - fetchFriendMessages / fetchGroupMessages: attachment_kind/
//     attachment_url/attachment_meta decode correctly end-to-end from the
//     real (snake_case) wire shape into FSMessage's camelCase fields; a
//     plain text-only message in the same response is unaffected
//     (regression guard).
//   - FSAttachmentMeta: both real backend shapes ({"filename"} for file;
//     {"url","preview_url","width","height"} for gif) decode correctly,
//     including the previewUrl <-> preview_url key mapping.
//
// Exercised against the real NetworkService (not MockDataService) via the
// shared StubURLProtocol harness (see NetworkServiceGetErrorHandlingTests.swift)
// for fellowscript.com-bound calls, plus a dedicated any-host stub for the
// direct-to-S3 upload (which deliberately never touches fellowscript.com).

import XCTest
@testable import FellowScript

/// Intercepts every request regardless of host -- needed for
/// `uploadAttachment`, which POSTs straight to a presigned S3 URL
/// (`mock-bucket.s3.amazonaws.com`-style), never `fellowscript.com`, unlike
/// every other NetworkService call `StubURLProtocol` (host-scoped) covers.
final class AnyHostStubURLProtocol: URLProtocol {
    static var stubStatusCode = 200
    static var stubBody: Data = Data()
    static var lastRequestURL: String?
    static var lastRequestBody: Data?

    static func reset() {
        stubStatusCode = 200
        stubBody = Data()
        lastRequestURL = nil
        lastRequestBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequestURL = request.url?.absoluteString
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 8192
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read > 0 { data.append(buffer, count: read) } else { break }
            }
            Self.lastRequestBody = data
        } else {
            Self.lastRequestBody = request.httpBody
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.stubStatusCode,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/xml"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stubBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MessagingAttachmentsNetworkServiceTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    // MARK: - requestAttachmentUploadURL

    func test_requestAttachmentUploadURL_postsCorrectPathAndBody_decodesPolicy() async throws {
        StubURLProtocol.resetRequestLog()
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"""
        {"url": "https://mock-bucket.s3.amazonaws.com", "fields": {"key": "attachments/u1/x.jpg", "policy": "abc"}, "object_key": "attachments/u1/x.jpg", "expires_in": 300}
        """#.data(using: .utf8)!

        let info = try await NetworkService.shared.requestAttachmentUploadURL(
            userId: "u1", attachmentKind: "image", contentType: "image/jpeg", sizeBytes: 1024
        )

        let logged = StubURLProtocol.requestLog.last
        XCTAssertEqual(logged?.path, "/api/message/upload-url/u1", "apiBase carries a \"/api\" prefix, baked into every NetworkService request path")
        XCTAssertEqual(logged?.method, "POST")
        XCTAssertEqual(logged?.bodyJSON?["attachment_kind"] as? String, "image")
        XCTAssertEqual(logged?.bodyJSON?["content_type"] as? String, "image/jpeg")
        XCTAssertEqual(logged?.bodyJSON?["size_bytes"] as? Int, 1024)

        XCTAssertEqual(info.url, "https://mock-bucket.s3.amazonaws.com")
        XCTAssertEqual(info.object_key, "attachments/u1/x.jpg")
        XCTAssertEqual(info.fields["policy"], "abc")
        XCTAssertEqual(info.expires_in, 300)
    }

    func test_requestAttachmentUploadURL_throws_on400_insteadOfSilentlyReturning() async {
        StubURLProtocol.stubStatusCode = 400
        StubURLProtocol.stubBody = #"{"detail": "Unsupported attachment_kind/content_type combination"}"#.data(using: .utf8)!

        do {
            _ = try await NetworkService.shared.requestAttachmentUploadURL(
                userId: "u1", attachmentKind: "image", contentType: "video/mp4", sizeBytes: 100
            )
            XCTFail("must throw on a 400 response, not silently return a policy")
        } catch {
            // any thrown error is correct -- the point is it does NOT return successfully
        }
    }

    func test_requestAttachmentUploadURL_throws_whenResponseBodyIsUndecodable() async {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"{"unexpected": "shape"}"#.data(using: .utf8)!

        do {
            _ = try await NetworkService.shared.requestAttachmentUploadURL(
                userId: "u1", attachmentKind: "file", contentType: "application/pdf", sizeBytes: 10
            )
            XCTFail("an undecodable 200 body must still throw, not return a bogus/empty policy silently")
        } catch {
            // expected
        }
    }

    // MARK: - uploadAttachment

    func test_uploadAttachment_postsMultipartFormDirectlyToPresignedURL_notApiBase() async throws {
        URLProtocol.registerClass(AnyHostStubURLProtocol.self)
        defer { URLProtocol.unregisterClass(AnyHostStubURLProtocol.self) }
        AnyHostStubURLProtocol.reset()
        AnyHostStubURLProtocol.stubStatusCode = 204

        let uploadInfo = FSUploadURLInfo(
            url: "https://mock-bucket.s3.amazonaws.com/upload",
            fields: ["key": "attachments/u1/photo.jpg", "policy": "signed-policy-doc"],
            object_key: "attachments/u1/photo.jpg", expires_in: 300
        )
        let fileData = "fake-image-bytes".data(using: .utf8)!

        try await NetworkService.shared.uploadAttachment(fileData: fileData, contentType: "image/jpeg", uploadInfo: uploadInfo)

        XCTAssertEqual(AnyHostStubURLProtocol.lastRequestURL, "https://mock-bucket.s3.amazonaws.com/upload",
                       "must POST straight to the presigned S3 URL, never this app's own API")
        let bodyString = String(data: AnyHostStubURLProtocol.lastRequestBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("attachments/u1/photo.jpg"), "every presigned field must ride ahead of the file part")
        XCTAssertTrue(bodyString.contains("signed-policy-doc"))
        XCTAssertTrue(bodyString.contains("fake-image-bytes"), "the actual file bytes must be included")
    }

    func test_uploadAttachment_throws_onNon2xxS3Response_insteadOfSilentlySucceeding() async {
        URLProtocol.registerClass(AnyHostStubURLProtocol.self)
        defer { URLProtocol.unregisterClass(AnyHostStubURLProtocol.self) }
        AnyHostStubURLProtocol.reset()
        AnyHostStubURLProtocol.stubStatusCode = 403 // e.g. an expired/mismatched presigned policy

        let uploadInfo = FSUploadURLInfo(url: "https://mock-bucket.s3.amazonaws.com/upload", fields: [:], object_key: "k", expires_in: 300)
        do {
            try await NetworkService.shared.uploadAttachment(fileData: Data([1, 2, 3]), contentType: "image/jpeg", uploadInfo: uploadInfo)
            XCTFail("a 403 from S3 must throw, not be silently treated as success")
        } catch {
            // expected
        }
    }

    // MARK: - searchGifs

    func test_searchGifs_blankQuery_shortCircuitsWithNoNetworkCall() async throws {
        StubURLProtocol.resetRequestLog()
        let results = try await NetworkService.shared.searchGifs(query: "   ")
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(StubURLProtocol.requestLog.isEmpty, "a blank query must not make a network call at all")
    }

    func test_searchGifs_realQuery_hitsCorrectEndpointAndUnwrapsResults() async throws {
        StubURLProtocol.resetRequestLog()
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"""
        {"results": [{"id": "g1", "url": "https://example.com/g1.gif", "preview_url": "https://example.com/g1-small.gif", "width": 200, "height": 150}]}
        """#.data(using: .utf8)!

        let results = try await NetworkService.shared.searchGifs(query: "cat dog")

        XCTAssertEqual(StubURLProtocol.requestLog.last?.path, "/api/message/gif-search", "apiBase carries a \"/api\" prefix, baked into every NetworkService request path")
        XCTAssertTrue(StubURLProtocol.requestLog.last?.url.contains("q=cat%20dog") ?? false,
                      "the query must be URL-encoded, got: \(StubURLProtocol.requestLog.last?.url ?? "")")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "g1")
        XCTAssertEqual(results.first?.width, 200)
    }

    func test_searchGifs_undecodableResponse_degradesToEmptyArray_notThrowOrCrash() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"{"totally": "unexpected"}"#.data(using: .utf8)!

        let results = try await NetworkService.shared.searchGifs(query: "cat")
        XCTAssertTrue(results.isEmpty, "an undecodable GIF-search response should degrade to no results, not crash the thread")
    }

    // MARK: - Attachment round-trip through fetchFriendMessages / fetchGroupMessages

    func test_fetchFriendMessages_decodesAttachmentFieldsCorrectly_andLeavesPlainTextMessagesUnaffected() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"""
        {
          "host_msgs": [
            {"id": "m1", "text": "", "timestamp": "2026-09-04T10:00:00Z",
             "attachment_kind": "image", "attachment_url": "https://s3.example.com/presigned-a",
             "attachment_meta": {"width": 800, "height": 600}}
          ],
          "other_msgs": [
            {"id": "m2", "text": "hey there", "timestamp": "2026-09-04T10:01:00Z"}
          ]
        }
        """#.data(using: .utf8)!

        let messages = try await NetworkService.shared.fetchFriendMessages(userId: "u1", friendId: "u2")
        XCTAssertEqual(messages.count, 2)

        let attachment = messages.first { $0.id == "m1" }
        XCTAssertEqual(attachment?.attachmentKind, "image")
        XCTAssertEqual(attachment?.attachmentURL, "https://s3.example.com/presigned-a")
        XCTAssertEqual(attachment?.attachmentMeta?.width, 800)
        XCTAssertEqual(attachment?.attachmentMeta?.height, 600)

        // Regression: a plain text message in the very same response must
        // decode with no attachment fields at all -- not a crash, not a
        // spuriously-populated attachment_kind.
        let plain = messages.first { $0.id == "m2" }
        XCTAssertEqual(plain?.text, "hey there")
        XCTAssertNil(plain?.attachmentKind)
        XCTAssertNil(plain?.attachmentURL)
        XCTAssertNil(plain?.attachmentMeta)
    }

    func test_fetchGroupMessages_decodesGifAttachmentMetaShape() async throws {
        StubURLProtocol.stubStatusCode = 200
        StubURLProtocol.stubBody = #"""
        {
          "host_msgs": [],
          "other_msgs": [
            {"id": "m3", "from_user": "u9", "text": "", "timestamp": "2026-09-04T10:02:00Z",
             "attachment_kind": "gif",
             "attachment_meta": {"url": "https://giphy.example/full.gif", "preview_url": "https://giphy.example/small.gif", "width": 220, "height": 180}}
          ]
        }
        """#.data(using: .utf8)!

        let messages = try await NetworkService.shared.fetchGroupMessages(userId: "u1", groupId: "g1")
        let gifMsg = messages.first { $0.id == "m3" }
        XCTAssertEqual(gifMsg?.attachmentKind, "gif")
        XCTAssertEqual(gifMsg?.attachmentMeta?.url, "https://giphy.example/full.gif")
        XCTAssertEqual(gifMsg?.attachmentMeta?.previewUrl, "https://giphy.example/small.gif")
        XCTAssertNil(gifMsg?.attachmentURL, "a gif never carries a resolved attachment_url -- its playable URL lives in attachment_meta.url")
    }

    // MARK: - FSAttachmentMeta decode shapes

    func test_FSAttachmentMeta_decodesFileShape() throws {
        let data = #"{"filename": "report.pdf"}"#.data(using: .utf8)!
        let meta = try JSONDecoder().decode(FSAttachmentMeta.self, from: data)
        XCTAssertEqual(meta.filename, "report.pdf")
        XCTAssertNil(meta.url)
        XCTAssertNil(meta.width)
    }

    func test_FSAttachmentMeta_decodesGifShape_withPreviewUrlKeyMapping() throws {
        let data = #"{"url": "https://example.com/full.gif", "preview_url": "https://example.com/small.gif", "width": 320, "height": 240}"#.data(using: .utf8)!
        let meta = try JSONDecoder().decode(FSAttachmentMeta.self, from: data)
        XCTAssertEqual(meta.url, "https://example.com/full.gif")
        XCTAssertEqual(meta.previewUrl, "https://example.com/small.gif")
        XCTAssertEqual(meta.width, 320)
        XCTAssertEqual(meta.height, 240)
        XCTAssertNil(meta.filename)
    }

    func test_FSAttachmentMeta_decodesEmptyObject_allFieldsNil() throws {
        let data = "{}".data(using: .utf8)!
        let meta = try JSONDecoder().decode(FSAttachmentMeta.self, from: data)
        XCTAssertEqual(meta, FSAttachmentMeta())
    }
}
