// NetworkService+ShareLinks.swift — task 20261011-ios-share-notes-highlights.
// Client calls behind the /g/<public_id> request-to-join link:
//   GET  /explorer/{user}/groups/{group}/share-link   member-only: the group's published listing public_id (generic 404 otherwise)
//   GET  /explorer/listings/{public_id}               public listing detail (title shown from the server, never from the URL)
//   POST /join-requests/{user}/listings/{public_id}/request   the ONLY action; always behind an explicit tap
//
// Fail closed: a 404 (not a member, not published, flag off, closed) and an
// unavailable listing are indistinguishable to the UI. Nothing is cached or
// persisted, and no id or URL is logged.
//
// Declared as its own small protocol (not DataServiceProtocol requirements) so the
// mock and any test double keep compiling; callers use `service as? ShareLinkService`
// and treat "not supported" as "hide / unavailable".

import Foundation

enum FSShareLinkError: Error, Equatable {
    /// Same outcome for 404 / flag off / closed / hidden: nothing is revealed.
    case unavailable
    case rateLimited
    case failed
}

/// The few public listing fields the confirm screen shows (all plain text).
struct FSListingPreview: Decodable, Equatable {
    let publicId: String
    let title: String
    let summary: String?
    let churchName: String?
    let city: String?
    let region: String?
    let requestable: Bool

    enum CodingKeys: String, CodingKey {
        case publicId = "public_id", title, summary
        case churchName = "church_name", city, region, requestable
    }

    var locationLine: String? {
        let parts = [city, region].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

enum FSJoinRequestOutcome: Equatable {
    case requested
    case alreadyMember
}

protocol ShareLinkService {
    /// nil = no shareable listing (not published / not a member / closed / flag off).
    func fetchGroupShareLinkPublicId(userId: String, groupId: String) async throws -> String?
    func fetchListingPreview(publicId: String) async throws -> FSListingPreview
    func requestToJoinListing(userId: String, publicId: String) async throws -> FSJoinRequestOutcome
}

private struct ShareLinkIdResponse: Decodable { let public_id: String }
private struct JoinRequestStatusResponse: Decodable { let status: String? }

extension NetworkService: ShareLinkService {

    private func shareLinkSend(_ path: String, method: String) async throws -> (Int, Data) {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.timeoutInterval = Self.requestTimeout
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw FSShareLinkError.failed }
            return (http.statusCode, data)
        } catch let e as FSShareLinkError {
            throw e
        } catch {
            throw FSShareLinkError.failed
        }
    }

    func fetchGroupShareLinkPublicId(userId: String, groupId: String) async throws -> String? {
        let (status, data) = try await shareLinkSend(
            "/explorer/\(encodeURIComponent(userId))/groups/\(encodeURIComponent(groupId))/share-link", method: "GET")
        if status == 404 { return nil }
        if status == 429 { throw FSShareLinkError.rateLimited }
        guard (200..<300).contains(status) else { throw FSShareLinkError.failed }
        guard let body = try? JSONDecoder().decode(ShareLinkIdResponse.self, from: data),
              AppLink.isValidPublicId(body.public_id) else { return nil }
        return body.public_id
    }

    func fetchListingPreview(publicId: String) async throws -> FSListingPreview {
        guard AppLink.isValidPublicId(publicId) else { throw FSShareLinkError.unavailable }
        let (status, data) = try await shareLinkSend("/explorer/listings/\(publicId)", method: "GET")
        if status == 404 { throw FSShareLinkError.unavailable }
        if status == 429 { throw FSShareLinkError.rateLimited }
        guard (200..<300).contains(status) else { throw FSShareLinkError.failed }
        guard let preview = try? JSONDecoder().decode(FSListingPreview.self, from: data),
              preview.publicId == publicId else { throw FSShareLinkError.unavailable }
        return preview
    }

    func requestToJoinListing(userId: String, publicId: String) async throws -> FSJoinRequestOutcome {
        guard AppLink.isValidPublicId(publicId) else { throw FSShareLinkError.unavailable }
        let (status, data) = try await shareLinkSend(
            "/join-requests/\(encodeURIComponent(userId))/listings/\(publicId)/request", method: "POST")
        switch status {
        case 200, 201:
            let s = (try? JSONDecoder().decode(JoinRequestStatusResponse.self, from: data))?.status
            return s == "already_member" ? .alreadyMember : .requested
        case 404, 403: throw FSShareLinkError.unavailable
        case 429: throw FSShareLinkError.rateLimited
        default: throw FSShareLinkError.failed
        }
    }
}

/// The mock/offline service has no live Explorer: share and link features stay off.
extension MockDataService: ShareLinkService {
    func fetchGroupShareLinkPublicId(userId: String, groupId: String) async throws -> String? { nil }
    func fetchListingPreview(publicId: String) async throws -> FSListingPreview { throw FSShareLinkError.unavailable }
    func requestToJoinListing(userId: String, publicId: String) async throws -> FSJoinRequestOutcome { throw FSShareLinkError.unavailable }
}
