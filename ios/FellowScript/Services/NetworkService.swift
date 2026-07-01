// DEPENDENCY: Models.swift, MockDataService.swift
// Real network layer that conforms to DataServiceProtocol.
// Wire this into AppState instead of MockDataService when the backend is live.
// Base URL mirrors frontend/src/config.js API constant.

import Foundation

final class NetworkService: DataServiceProtocol {
    static let shared = NetworkService()
    private init() {}

    private let base = "https://fellowscript.com/api"  // replace with actual API URL

    private func url(_ path: String) -> URL {
        URL(string: base + path)!
    }

    func signIn(username: String, password: String) async throws -> FSUser {
        var req = URLRequest(url: url("/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["username": username, "plain_pass": password])
        let (data, res) = try await URLSession.shared.data(for: req)
        guard (res as? HTTPURLResponse)?.statusCode == 200 else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"] ?? "Sign in failed."
            throw AppError.authFailed(detail)
        }
        return try JSONDecoder().decode(FSUser.self, from: data)
    }

    func signUp(username: String, email: String, password: String) async throws -> FSUser {
        var req = URLRequest(url: url("/signup"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["username": username, "email": email, "plain_pass": password])
        let (data, res) = try await URLSession.shared.data(for: req)
        guard (res as? HTTPURLResponse)?.statusCode == 200 else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"] ?? "Sign up failed."
            throw AppError.authFailed(detail)
        }
        return try JSONDecoder().decode(FSUser.self, from: data)
    }

    func fetchNotes(userId: String) async throws -> [String: FSNote] {
        let (data, _) = try await URLSession.shared.data(from: url("/notes/\(userId)"))
        return (try? JSONDecoder().decode([String: FSNote].self, from: data)) ?? [:]
    }

    func fetchHighlights(userId: String) async throws -> [String: String] {
        let (data, _) = try await URLSession.shared.data(from: url("/notes/highlight/\(userId)"))
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    func fetchBookmarks(userId: String) async throws -> [String: String] {
        let (data, _) = try await URLSession.shared.data(from: url("/notes/bookmark/\(userId)"))
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    func fetchAgents(userId: String) async throws -> [FSAgent] {
        let (data, _) = try await URLSession.shared.data(from: url("/agent/\(userId)"))
        guard let dict = try? JSONDecoder().decode([String: FSAgent].self, from: data) else { return [] }
        return dict.map { FSAgent(id: $0.key, user_id: $0.value.user_id, role: $0.value.role, enabled: $0.value.enabled, chats: $0.value.chats) }
    }

    func fetchContacts(userId: String) async throws -> ([FSContact], [String: FSGroup]) {
        // Fetches user profile to get friends + groups, then resolves each
        let (data, _) = try await URLSession.shared.data(from: url("/user/\(userId)"))
        guard let profile = try? JSONDecoder().decode(FSUser.self, from: data) else { return ([], [:]) }

        let friends: [FSContact] = await withTaskGroup(of: FSContact?.self) { g in
            for fid in profile.friends {
                g.addTask {
                    guard let (d, _) = try? await URLSession.shared.data(from: URL(string: self.base + "/user/\(fid)")!),
                          let u = try? JSONDecoder().decode(FSUser.self, from: d) else { return nil }
                    return FSContact(id: fid, name: u.username, type: .friend)
                }
            }
            var result: [FSContact] = []
            for await c in g { if let c { result.append(c) } }
            return result
        }

        // Groups stub — extend similarly
        return (friends, [:])
    }

    func fetchMessages(contactId: String, userId: String, isGroup: Bool) async throws -> [FSMessage] {
        // WebSocket is used for real-time; REST endpoint for history not yet in spec
        return []
    }

    func fetchSessions(userId: String, groupId: String) async throws -> [FSSession] {
        let (data, _) = try await URLSession.shared.data(from: url("/sessions/\(groupId)/\(userId)"))
        return (try? JSONDecoder().decode([FSSession].self, from: data)) ?? []
    }
}
