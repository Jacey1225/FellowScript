// NetworkService+Attachments.swift — presigned-upload-URL request, direct-
// to-S3 upload, and GIF search (task 20260904-messaging-attachments). Split
// out of NetworkService.swift (readability #H16, 20260904-frontend-arch-
// sweep) -- same type, same behavior, just this domain's own file. See
// NetworkService.swift's header comment for the full split rationale and
// the list of sibling domain files.

import Foundation

// ── Attachments (task 20260904-messaging-attachments) ────────────────────
// Wire contract per design-notes.md's "Wire contract" section / backend
// step 2: request a presigned S3 POST policy over plain HTTP, then upload
// the raw bytes directly to S3 with it — this server never receives the
// file itself. GIF search is a thin authenticated proxy (backend step 2)
// so the provider API key never reaches this client.

private struct AttachmentUploadURLBody: Encodable {
    let attachment_kind: String
    let content_type:    String
    let size_bytes:      Int?
}

private struct RawGifSearchResponse: Decodable {
    let results: [FSGifResult]
}

// Task 20260905-gif-picker-default-browse: default/trending browse envelope
// — `next_page_token` is opaque (Giphy's integer offset vs. Tenor's cursor,
// normalized server-side per design gate §7's wire contract) and is only
// ever round-tripped back to the server unmodified, never parsed here.
private struct RawGifBrowseResponse: Decodable {
    let results:         [FSGifResult]
    let next_page_token: String?
    let has_more:        Bool
}

// ── Profile photo (task 20260905-profile-photo) ──────────────────────────
// Same presigned-S3-POST wire contract as the message attachments above --
// `uploadAttachment` (defined above) is reused verbatim for the raw-bytes
// step; only the URL-request/confirm/remove endpoints differ, since a
// profile photo is always the "image" kind and lives under its own S3
// prefix + `users.profile_photo_key` column (routes/profile_photo.py).

private struct ProfilePhotoUploadURLBody: Encodable {
    let content_type: String
    let size_bytes:   Int?
}

private struct ProfilePhotoConfirmBody: Encodable {
    let object_key: String
}

private struct ProfilePhotoConfirmResponse: Decodable {
    let profile_photo_url: String?
}

extension NetworkService {

    // POST /message/upload-url/{userId} → {url, fields, object_key, expires_in}
    func requestAttachmentUploadURL(userId: String, attachmentKind: String, contentType: String, sizeBytes: Int?) async throws -> FSUploadURLInfo {
        let body = AttachmentUploadURLBody(attachment_kind: attachmentKind, content_type: contentType, size_bytes: sizeBytes)
        let data = try await request("/message/upload-url/\(userId)", method: "POST", body: body)
        guard let info = decode(FSUploadURLInfo.self, from: data, endpoint: "/message/upload-url") else {
            throw AppError.networkError("Could not prepare that upload. Please try again.")
        }
        return info
    }

    /// Uploads raw bytes directly to S3 using the presigned POST policy from
    /// `requestAttachmentUploadURL` — a multipart/form-data POST straight to
    /// `uploadInfo.url`, not this app's own API (`apiBase` is deliberately
    /// unused here). `uploadInfo.fields` must ride ahead of the file part
    /// (S3's presigned-POST contract), and every field key must be present
    /// exactly as issued — the policy's signature covers them.
    func uploadAttachment(fileData: Data, contentType: String, uploadInfo: FSUploadURLInfo) async throws {
        guard let uploadURL = URL(string: uploadInfo.url) else {
            throw AppError.networkError("Could not reach upload storage.")
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: uploadURL)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        for (key, value) in uploadInfo.fields {
            appendField(key, value)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"upload\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("[NetworkService] Attachment upload to S3 failed with status \(status)")
            throw AppError.networkError("Upload failed. Please try again.")
        }
    }

    // GET /message/gif-search?q= → {results: [...]}
    func searchGifs(query: String) async throws -> [FSGifResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        let data = try await get("/message/gif-search?q=\(encoded)")
        guard let resp = decode(RawGifSearchResponse.self, from: data, endpoint: "/message/gif-search") else { return [] }
        return resp.results
    }

    // GET /message/gif-search[?page_token=] → {results, next_page_token, has_more}
    // Default/trending browse (task 20260905-gif-picker-default-browse) —
    // omitting `q` switches the same authenticated proxy endpoint to browse
    // mode server-side. `pageToken` is opaque: pass back a previous call's
    // `nextPageToken` unmodified to fetch the next page, or `nil` for the
    // first page.
    func browseGifs(pageToken: String?) async throws -> (results: [FSGifResult], nextPageToken: String?, hasMore: Bool) {
        var path = "/message/gif-search"
        if let pageToken, !pageToken.isEmpty {
            let encoded = pageToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pageToken
            path += "?page_token=\(encoded)"
        }
        let data = try await get(path)
        guard let resp = decode(RawGifBrowseResponse.self, from: data, endpoint: "/message/gif-search") else {
            throw AppError.networkError("Couldn't load GIFs right now — try again in a moment.")
        }
        return (resp.results, resp.next_page_token, resp.has_more)
    }

    // POST /user/{userId}/photo/upload-url → {url, fields, object_key, expires_in}
    func requestProfilePhotoUploadURL(userId: String, contentType: String, sizeBytes: Int?) async throws -> FSUploadURLInfo {
        let body = ProfilePhotoUploadURLBody(content_type: contentType, size_bytes: sizeBytes)
        let data = try await request("/user/\(userId)/photo/upload-url", method: "POST", body: body)
        guard let info = decode(FSUploadURLInfo.self, from: data, endpoint: "/user/{id}/photo/upload-url") else {
            throw AppError.networkError("Could not prepare that upload. Please try again.")
        }
        return info
    }

    // POST /user/{userId}/photo/confirm → {profile_photo_url}
    func confirmProfilePhoto(userId: String, objectKey: String) async throws -> String? {
        let body = ProfilePhotoConfirmBody(object_key: objectKey)
        let data = try await request("/user/\(userId)/photo/confirm", method: "POST", body: body)
        guard let resp = decode(ProfilePhotoConfirmResponse.self, from: data, endpoint: "/user/{id}/photo/confirm") else {
            throw AppError.networkError("Could not save your new photo. Please try again.")
        }
        return resp.profile_photo_url
    }

    // DELETE /user/{userId}/photo — idempotent; a 204 with no photo
    // previously set is not an error (mirrors the backend's own contract).
    func removeProfilePhoto(userId: String) async throws {
        _ = try await request("/user/\(userId)/photo", method: "DELETE")
    }
}
