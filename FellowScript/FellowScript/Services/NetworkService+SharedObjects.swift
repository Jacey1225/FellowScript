// NetworkService+SharedObjects.swift — task 20261012-share-verses-notes-in-chat.
// Read-only fetch of a note shared into a chat:
//   GET /shared-objects/{user_id}/note/{message_id}
// The chat message is the share grant. Every failure (flag off, not a
// participant, revoked, note gone) is one uniform 404 server-side, so this
// client also surfaces exactly one "unavailable" outcome and never guesses why.

import Foundation

/// A note opened through a chat share, plus who sent it (nil when the sender is the author).
struct FSSharedNote {
    let note: FSNote
    let sharedBy: String?
}

enum FSSharedObjectError: Error { case unavailable }

protocol SharedObjectsService {
    func fetchSharedNote(userId: String, messageId: String) async throws -> FSSharedNote
}

extension NetworkService: SharedObjectsService {
    func fetchSharedNote(userId: String, messageId: String) async throws -> FSSharedNote {
        let data: Data
        do {
            data = try await get("/shared-objects/\(encodeURIComponent(userId))/note/\(encodeURIComponent(messageId))")
        } catch {
            throw FSSharedObjectError.unavailable
        }
        guard var note = try? JSONDecoder().decode(FSNote.self, from: data),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["read_only"] as? Bool == true,
              let noteId = obj["note_id"] as? String else {
            throw FSSharedObjectError.unavailable
        }
        note.id = noteId
        note.group_id = ""   // read-only view: no replies, no group-edit rules
        let by = (obj["shared_by"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return FSSharedNote(note: note, sharedBy: by)
    }
}

/// The mock/offline service has no chat shares.
extension MockDataService: SharedObjectsService {
    func fetchSharedNote(userId: String, messageId: String) async throws -> FSSharedNote {
        throw FSSharedObjectError.unavailable
    }
}
