// NetworkService+GroupInfo.swift — group info panel endpoints (task
// 20260929-group-info-panel): rename, group photo (presigned upload /
// confirm / remove), per-user mute, and the attachment gallery. All are
// member-only server-side (api/routes/group_info.py). Every method throws on
// any failure (throw-not-fabricate) -- callers keep their cached value and
// surface the error.

import Foundation

private struct GroupTitleBody: Encodable { let title: String }
private struct GroupTitleResponse: Decodable { let title: String }
private struct GroupMuteResponse: Decodable { let muted: Bool }
private struct GroupMaxMembersBody: Encodable {
    let max_members: Int?
    // Explicit null clears the cap (the synthesized encoder would omit nil).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(max_members, forKey: .max_members)
    }
    enum CodingKeys: String, CodingKey { case max_members }
}
private struct GroupMaxMembersResponse: Decodable { let max_members: Int? }
private struct GroupPhotoUploadURLBody: Encodable {
    let content_type: String
    let size_bytes:   Int?
}
private struct GroupPhotoConfirmBody: Encodable { let object_key: String }
private struct GroupPhotoConfirmResponse: Decodable { let photo_url: String? }
private struct GroupPhotoRemoveResponse: Decodable { let restore_key: String? }

extension NetworkService {

    // GET /groups/{userId}/{groupId}/info
    func fetchGroupInfo(userId: String, groupId: String) async throws -> FSGroupInfo {
        let data = try await get("/groups/\(userId)/\(groupId)/info")
        guard let info = decode(FSGroupInfo.self, from: data, endpoint: "/groups/{id}/{id}/info") else {
            throw AppError.networkError("Couldn't refresh just now.")
        }
        return info
    }

    // PUT /groups/{userId}/{groupId}/title → {group_id, title}
    func renameGroup(userId: String, groupId: String, title: String) async throws -> String {
        let data = try await request("/groups/\(userId)/\(groupId)/title", method: "PUT", body: GroupTitleBody(title: title))
        guard let resp = decode(GroupTitleResponse.self, from: data, endpoint: "/groups/{id}/{id}/title") else {
            throw AppError.networkError("That name didn't save. Please try again.")
        }
        return resp.title
    }

    // PUT /groups/{userId}/{groupId}/max-members → {group_id, max_members}
    // Owner only (403 otherwise); nil clears the cap. 422 carries a
    // user-presentable detail (out of range / below current member count).
    func setGroupMaxMembers(userId: String, groupId: String, maxMembers: Int?) async throws -> Int? {
        let data = try await request("/groups/\(userId)/\(groupId)/max-members", method: "PUT", body: GroupMaxMembersBody(max_members: maxMembers))
        guard let resp = decode(GroupMaxMembersResponse.self, from: data, endpoint: "/groups/{id}/{id}/max-members") else {
            throw AppError.networkError("Couldn't save the limit. Please try again.")
        }
        return resp.max_members
    }

    // PUT /DELETE /groups/{userId}/{groupId}/mute → {muted}
    func setGroupMuted(userId: String, groupId: String, muted: Bool) async throws -> Bool {
        let data = try await request("/groups/\(userId)/\(groupId)/mute", method: muted ? "PUT" : "DELETE")
        guard let resp = decode(GroupMuteResponse.self, from: data, endpoint: "/groups/{id}/{id}/mute") else {
            throw AppError.networkError("Couldn't update notifications. Please try again.")
        }
        return resp.muted
    }

    // POST /groups/{userId}/{groupId}/photo/upload-url → {url, fields, object_key, expires_in}
    func requestGroupPhotoUploadURL(userId: String, groupId: String, contentType: String, sizeBytes: Int?) async throws -> FSUploadURLInfo {
        let body = GroupPhotoUploadURLBody(content_type: contentType, size_bytes: sizeBytes)
        let data = try await request("/groups/\(userId)/\(groupId)/photo/upload-url", method: "POST", body: body)
        guard let info = decode(FSUploadURLInfo.self, from: data, endpoint: "/groups/{id}/{id}/photo/upload-url") else {
            throw AppError.networkError("Could not prepare that upload. Please try again.")
        }
        return info
    }

    // POST /groups/{userId}/{groupId}/photo/confirm → {photo_url}
    // Also restores a just-removed photo when given the remove call's restore_key.
    func confirmGroupPhoto(userId: String, groupId: String, objectKey: String) async throws -> String? {
        let data = try await request("/groups/\(userId)/\(groupId)/photo/confirm", method: "POST", body: GroupPhotoConfirmBody(object_key: objectKey))
        guard let resp = decode(GroupPhotoConfirmResponse.self, from: data, endpoint: "/groups/{id}/{id}/photo/confirm") else {
            throw AppError.networkError("Couldn't save the photo. Please try again.")
        }
        return resp.photo_url
    }

    // DELETE /groups/{userId}/{groupId}/photo → {restore_key}. The S3 object
    // is kept server-side so the client can offer undo via confirmGroupPhoto.
    func removeGroupPhoto(userId: String, groupId: String) async throws -> String? {
        let data = try await request("/groups/\(userId)/\(groupId)/photo", method: "DELETE")
        guard let resp = decode(GroupPhotoRemoveResponse.self, from: data, endpoint: "/groups/{id}/{id}/photo") else {
            throw AppError.networkError("Couldn't remove the photo. Please try again.")
        }
        return resp.restore_key
    }

    // GET /groups/{userId}/{groupId}/gallery?kind=&cursor_timestamp=&cursor_id=
    func fetchGroupGallery(userId: String, groupId: String, kind: String?, cursorTimestamp: String?, cursorId: String?) async throws -> FSGalleryPage {
        var query: [String] = []
        if let kind { query.append("kind=\(encodeURIComponent(kind))") }
        if let cursorTimestamp, let cursorId {
            query.append("cursor_timestamp=\(encodeURIComponent(cursorTimestamp))")
            query.append("cursor_id=\(encodeURIComponent(cursorId))")
        }
        let qs = query.isEmpty ? "" : "?" + query.joined(separator: "&")
        let data = try await get("/groups/\(userId)/\(groupId)/gallery\(qs)")
        guard let page = decode(FSGalleryPage.self, from: data, endpoint: "/groups/{id}/{id}/gallery") else {
            throw AppError.networkError("Couldn't load shared items.")
        }
        return page
    }
}
