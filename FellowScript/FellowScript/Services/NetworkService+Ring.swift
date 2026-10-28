// NetworkService+Ring.swift: ring lifecycle routes (task 20261028-dm-direct-call).
//   POST /devotions/ring/respond  {devotion_id, user_id, target_id, outcome}
//        target sends answered|declined, the ring's caller sends canceled.
//   GET  /devotions/ring/status?devotion_id=&user_id=
//        -> {"rings": {target_id: {"status", "seconds_left"}}} (caller's rings)
// Own protocol (like DmCallServiceProtocol) so DataServiceProtocol test
// doubles are unaffected. The server owns the ring timeout (45s); the client
// only reports what the user did and reads back what the server decided.

import Foundation

enum RingOutcome: String {
    case answered, declined, canceled
}

/// One ring's live state as the server reports it. `status` is one of
/// ringing | answered | declined | canceled | timed_out.
struct RingStatusEntry: Decodable, Equatable {
    let status: String
    let seconds_left: Double?
}

private struct RingStatusResponse: Decodable {
    let rings: [String: RingStatusEntry]
}

protocol RingLifecycleServiceProtocol {
    func respondToRing(devotionId: String, userId: String, targetId: String, outcome: RingOutcome) async throws
    func fetchRingStatus(devotionId: String, userId: String) async throws -> [String: RingStatusEntry]
}

extension NetworkService: RingLifecycleServiceProtocol {
    func respondToRing(devotionId: String, userId: String, targetId: String, outcome: RingOutcome) async throws {
        let body: [String: Any] = [
            "devotion_id": devotionId,
            "user_id": userId,
            "target_id": targetId,
            "outcome": outcome.rawValue,
        ]
        _ = try await checkedRequestRaw("/devotions/ring/respond", method: "POST", jsonObject: body)
    }

    func fetchRingStatus(devotionId: String, userId: String) async throws -> [String: RingStatusEntry] {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))
        let d = devotionId.addingPercentEncoding(withAllowedCharacters: allowed) ?? devotionId
        let u = userId.addingPercentEncoding(withAllowedCharacters: allowed) ?? userId
        let data = try await get("/devotions/ring/status?devotion_id=\(d)&user_id=\(u)")
        guard let response = decode(RingStatusResponse.self, from: data, endpoint: "/devotions/ring/status") else {
            throw AppError.networkError("Couldn't read the ring status.")
        }
        return response.rings
    }
}
