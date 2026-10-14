// NetworkService+TranscriptRelay.swift: /devotions/transcript/* calls (task
// 20261013-session-call-live-transcript-summary). Deliberately NOT routed
// through request()/throwIfError(): the outcome is reduced to a small enum so
// no response text, and certainly no transcript text, can reach logs or UI.
// Writes are never retried here (the relay re-queues bounded batches itself).

import Foundation

extension NetworkService: TranscriptRelayServiceProtocol {

    private func transcriptCall(_ action: String, userId: String, sessionId: String,
                                body: [String: Any]? = nil) async -> (status: Int, data: Data)? {
        let path = "/devotions/transcript/\(action)?user_id=\(encodeURIComponent(userId))&session_id=\(encodeURIComponent(sessionId))"
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.timeoutInterval = Self.requestTimeout
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }

    func transcriptRelayStatus(userId: String, sessionId: String) async -> TranscriptStatusResult {
        guard let r = await transcriptCall("relay-status", userId: userId, sessionId: sessionId) else { return .unreachable }
        if r.status == 404 { return .featureOff }
        guard (200..<300).contains(r.status),
              let status = try? JSONDecoder().decode(TranscriptRelayStatus.self, from: r.data) else { return .unreachable }
        return .ok(status)
    }

    func transcriptIngest(userId: String, sessionId: String, segments: [TranscriptSegment]) async -> TranscriptIngestResult {
        let payload: [[String: Any]] = segments.map { seg in
            var d: [String: Any] = ["text": seg.text]
            if let s = seg.speakerId { d["speaker_id"] = s }
            return d
        }
        guard let r = await transcriptCall("ingest", userId: userId, sessionId: sessionId,
                                           body: ["segments": payload]) else { return .retryLater }
        switch r.status {
        case 200..<300: return .accepted
        case 403, 404, 409: return .notRelay
        case 413, 422: return .dropped
        default: return .retryLater
        }
    }

    func transcriptLeave(userId: String, sessionId: String) async {
        _ = await transcriptCall("leave", userId: userId, sessionId: sessionId)
    }
}
