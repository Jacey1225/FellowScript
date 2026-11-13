// NetworkService+VerseAsk.swift -- task 20261112-verse-ask-ai (step 5).
// One-shot per-verse question over the EXISTING Ask AI socket
// (/ask-ai/ws/{userId}); there is no second AI path. The frame is the usual
// {content} plus verse_context {reference, translation, text}. The server
// answers with ONE ephemeral frame (role assistant|error; nothing saved, no
// chat id), so this connects, sends, awaits that frame and closes.
//
// Throw-not-fabricate: every failure (offline, timeout, transport, server
// error frame, empty or unparseable reply) throws a VerseAskError. A reply is
// plain text and must be rendered as text only.

import Foundation

struct VerseAskContext: Equatable {
    let reference: String
    let translation: String
    let text: String

    var wireObject: [String: String] {
        ["reference": reference, "translation": translation, "text": text]
    }
}

enum VerseAskError: Error, Equatable {
    case offline
    case timeout
    case network
    case server(String)
}

enum VerseAskFrame {
    /// Parses the single reply frame. Throws on error frames, empty content or
    /// anything that is not a JSON object.
    nonisolated static func parse(_ text: String) throws -> String {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VerseAskError.network
        }
        let content = (obj["content"] as? String) ?? ""
        if (obj["role"] as? String) == "error" {
            throw VerseAskError.server(content)
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VerseAskError.network
        }
        return content
    }

    /// Request frame sent on the socket.
    nonisolated static func request(question: String, context: VerseAskContext) throws -> String {
        let obj: [String: Any] = ["content": question, "verse_context": context.wireObject]
        let data = try JSONSerialization.data(withJSONObject: obj)
        guard let s = String(data: data, encoding: .utf8) else { throw VerseAskError.network }
        return s
    }
}

protocol VerseAskTransport {
    func askVerse(userId: String, question: String, context: VerseAskContext) async throws -> String
}

extension NetworkService: VerseAskTransport {
    static let verseAskTimeout: TimeInterval = 60

    func askVerse(userId: String, question: String, context: VerseAskContext) async throws -> String {
        let frame = try VerseAskFrame.request(question: question, context: context)
        guard let url = URL(string: "\(wsBase)/ask-ai/ws/\(userId)") else { throw VerseAskError.network }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await task.send(.string(frame))
                    switch try await task.receive() {
                    case .string(let s): return try VerseAskFrame.parse(s)
                    case .data(let d):
                        guard let s = String(data: d, encoding: .utf8) else { throw VerseAskError.network }
                        return try VerseAskFrame.parse(s)
                    @unknown default: throw VerseAskError.network
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(Self.verseAskTimeout * 1_000_000_000))
                    throw VerseAskError.timeout
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw VerseAskError.network }
                return first
            }
        } catch let e as VerseAskError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .notConnectedToInternet || e.code == .dataNotAllowed {
            throw VerseAskError.offline
        } catch {
            throw VerseAskError.network
        }
    }
}
