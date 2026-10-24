// NetworkService+AnnouncementPolls.swift — vote / retract / close endpoints for polls inside
// group announcements (task 20261024-announcement-polls; api/routes/group_announcements.py).
// Kept behind its own small protocol so GroupAnnouncementsService (and its mocks) don't grow.
// Every method throws on failure (throw-not-fabricate). Votes are anonymous server-side.

import Foundation

protocol AnnouncementPollsService {
    /// Replace the caller's selection (idempotent). Returns the announcement with live counts.
    func pollVote(userId: String, groupId: String, announcementId: String, optionIds: [String]) async throws -> FSGroupAnnouncement
    /// Clear the caller's selection (idempotent).
    func pollRetract(userId: String, groupId: String, announcementId: String) async throws -> FSGroupAnnouncement
    /// Close now (announcement creator or group creator).
    func pollClose(userId: String, groupId: String, announcementId: String) async throws -> FSGroupAnnouncement
}

private struct PollVoteBody: Encodable { let option_ids: [String] }

/// The three poll actions the detail card needs, already bound to one announcement.
struct AnnouncementPollActions {
    var vote: ([String]) async throws -> FSGroupAnnouncement
    var retract: () async throws -> FSGroupAnnouncement
    /// Nil when the viewer can't close the poll.
    var close: (() async throws -> FSGroupAnnouncement)? = nil

    /// Binds the service to one announcement; `onUpdated` lets the owner replace its cached copy.
    static func make(service: AnnouncementPollsService?, userId: String, groupId: String, item: FSGroupAnnouncement,
                     onUpdated: @escaping (FSGroupAnnouncement) async -> Void) -> AnnouncementPollActions? {
        guard let service else { return nil }
        let announcementId = item.id
        let vote: ([String]) async throws -> FSGroupAnnouncement = { ids in
            let u = try await service.pollVote(userId: userId, groupId: groupId, announcementId: announcementId, optionIds: ids)
            await onUpdated(u)
            return u
        }
        let retract: () async throws -> FSGroupAnnouncement = {
            let u = try await service.pollRetract(userId: userId, groupId: groupId, announcementId: announcementId)
            await onUpdated(u)
            return u
        }
        var actions = AnnouncementPollActions(vote: vote, retract: retract)
        if item.can_edit {
            actions.close = {
                let u = try await service.pollClose(userId: userId, groupId: groupId, announcementId: announcementId)
                await onUpdated(u)
                return u
            }
        }
        return actions
    }
}

extension NetworkService: AnnouncementPollsService {
    private func pollPath(_ userId: String, _ groupId: String, _ id: String) -> String {
        "/groups/\(userId)/\(groupId)/announcements/\(id)/poll"
    }

    private func decodePoll(_ data: Data, _ endpoint: String, _ fallback: String) throws -> FSGroupAnnouncement {
        guard let item = decode(FSGroupAnnouncement.self, from: data, endpoint: endpoint) else {
            throw AppError.networkError(fallback)
        }
        return item
    }

    func pollVote(userId: String, groupId: String, announcementId: String, optionIds: [String]) async throws -> FSGroupAnnouncement {
        let data = try await request("\(pollPath(userId, groupId, announcementId))/vote", method: "POST", body: PollVoteBody(option_ids: optionIds))
        return try decodePoll(data, "/groups/{id}/{id}/announcements/{id}/poll/vote", "Couldn't record your vote. Please try again.")
    }

    func pollRetract(userId: String, groupId: String, announcementId: String) async throws -> FSGroupAnnouncement {
        let data = try await request("\(pollPath(userId, groupId, announcementId))/vote", method: "DELETE")
        return try decodePoll(data, "/groups/{id}/{id}/announcements/{id}/poll/vote", "Couldn't clear your vote. Please try again.")
    }

    func pollClose(userId: String, groupId: String, announcementId: String) async throws -> FSGroupAnnouncement {
        let data = try await request("\(pollPath(userId, groupId, announcementId))/close", method: "POST")
        return try decodePoll(data, "/groups/{id}/{id}/announcements/{id}/poll/close", "Couldn't close the poll. Please try again.")
    }
}
