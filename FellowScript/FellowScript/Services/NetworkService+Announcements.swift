// NetworkService+Announcements.swift — group announcement endpoints (task
// 20260929-group-announcements), member-only server-side
// (api/routes/group_announcements.py). Kept in its own file and behind its
// own small protocol so neither NetworkService nor DataServiceProtocol grows.
// Every method throws on any failure (throw-not-fabricate). A free-limit 403
// surfaces as AppError.limitReached (via throwIfError).

import Foundation

protocol GroupAnnouncementsService {
    func fetchAnnouncements(userId: String, groupId: String) async throws -> FSAnnouncementsPage
    func createAnnouncement(userId: String, groupId: String, draft: FSAnnouncementDraft) async throws -> FSGroupAnnouncement
    func updateAnnouncement(userId: String, groupId: String, announcementId: String, draft: FSAnnouncementDraft) async throws -> FSGroupAnnouncement
    func deleteAnnouncement(userId: String, groupId: String, announcementId: String) async throws
    /// Presigned upload of a banner; returns the object key to attach on create/update.
    func uploadAnnouncementBanner(userId: String, groupId: String, data: Data, contentType: String) async throws -> String
}

private struct AnnouncementBannerUploadBody: Encodable {
    let content_type: String
    let size_bytes:   Int?
}

extension NetworkService: GroupAnnouncementsService {

    private func announcementsPath(_ userId: String, _ groupId: String) -> String {
        "/groups/\(userId)/\(groupId)/announcements"
    }

    // GET → {announcements, truncated, gate}
    func fetchAnnouncements(userId: String, groupId: String) async throws -> FSAnnouncementsPage {
        let data = try await get(announcementsPath(userId, groupId))
        guard let page = decode(FSAnnouncementsPage.self, from: data, endpoint: "/groups/{id}/{id}/announcements") else {
            throw AppError.networkError("Couldn't load announcements.")
        }
        return page
    }

    // POST → the created announcement
    func createAnnouncement(userId: String, groupId: String, draft: FSAnnouncementDraft) async throws -> FSGroupAnnouncement {
        let data = try await checkedRequestRaw(announcementsPath(userId, groupId), method: "POST", jsonObject: draft.jsonObject)
        guard let item = decode(FSGroupAnnouncement.self, from: data, endpoint: "/groups/{id}/{id}/announcements POST") else {
            throw AppError.networkError("That didn't save. Please try again.")
        }
        return item
    }

    // PUT → the updated announcement (only fields present are applied)
    func updateAnnouncement(userId: String, groupId: String, announcementId: String, draft: FSAnnouncementDraft) async throws -> FSGroupAnnouncement {
        let data = try await checkedRequestRaw("\(announcementsPath(userId, groupId))/\(announcementId)", method: "PUT", jsonObject: draft.jsonObject)
        guard let item = decode(FSGroupAnnouncement.self, from: data, endpoint: "/groups/{id}/{id}/announcements PUT") else {
            throw AppError.networkError("That didn't save. Please try again.")
        }
        return item
    }

    // DELETE (soft delete server-side)
    func deleteAnnouncement(userId: String, groupId: String, announcementId: String) async throws {
        _ = try await request("\(announcementsPath(userId, groupId))/\(announcementId)", method: "DELETE")
    }

    // POST …/announcements/banner/upload-url, then presigned POST to S3.
    func uploadAnnouncementBanner(userId: String, groupId: String, data: Data, contentType: String) async throws -> String {
        let body = AnnouncementBannerUploadBody(content_type: contentType, size_bytes: data.count)
        let resp = try await request("\(announcementsPath(userId, groupId))/banner/upload-url", method: "POST", body: body)
        guard let info = decode(FSUploadURLInfo.self, from: resp, endpoint: "/groups/{id}/{id}/announcements/banner/upload-url") else {
            throw AppError.networkError("Could not prepare that upload. Please try again.")
        }
        try await uploadAttachment(fileData: data, contentType: contentType, uploadInfo: info)
        return info.object_key
    }
}

extension Notification.Name {
    /// Posted by the announcements upgrade card; ContentView switches to the
    /// Account tab, where the subscription card lives.
    static let fsOpenSubscriptionPlans = Notification.Name("fsOpenSubscriptionPlans")
}
