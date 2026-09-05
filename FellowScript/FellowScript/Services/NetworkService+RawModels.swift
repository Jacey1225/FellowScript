// NetworkService+RawModels.swift — the private "wire shape" Decodable
// structs NetworkService.swift used to define at its own file's bottom,
// factored out here because more than one domain extension file now needs
// them (e.g. RawGroupResponse is decoded by both NetworkService+Contacts.swift's
// fetchContacts and NetworkService+Messaging.swift's fetchGroupMessages).
// Kept `internal` (no access modifier), not `private` -- Swift's `private`
// only extends to same-file extensions, so a cross-file-shared type can't
// stay `private` the way it could when everything lived in one file. Still
// invisible outside this app target. See NetworkService.swift's header
// comment for the full split rationale (readability #H16, 20260904-
// frontend-arch-sweep).

import Foundation

struct RawAgentMsg: Decodable {
    let content:   String
    let title:     String?   // "user" or "assistant"
    let timestamp: String?
}

struct RawMsg: Decodable {
    let id:        String?
    let text:      String?
    let from_user: String?
    let timestamp: String
    // Task 20260904-messaging-attachments: null/absent for an ordinary
    // text-only message. `attachment_url` (image/video/file only) is a
    // freshly presigned GET the server resolves at read time — never a
    // durable/storable URL.
    let attachment_kind: String?
    let attachment_meta: FSAttachmentMeta?
    let attachment_url:  String?
}

struct RawChatResponse: Decodable {
    let host_msgs:  [RawMsg]?
    let other_msgs: [RawMsg]?
}

struct RawFriendRequest: Decodable {
    let user_id:  String
    let username: String
}

struct RawGroup: Decodable {
    var title: String? = nil
    var users: [String]? = nil
}

struct RawGroupResponse: Decodable {
    let group:      RawGroup?
    let host_msgs:  [RawMsg]?
    let other_msgs: [RawMsg]?
    let members:    [String]?
}

struct RawMsgBody: Decodable {
    let host_msgs:  [RawMsg]?
    let other_msgs: [RawMsg]?

    var allMsgs: [RawMsg] { (host_msgs ?? []) + (other_msgs ?? []) }
}

struct RawMsgPayload: Decodable {
    let payload: RawMsgBody?
}

struct RawDevotionsResponse: Decodable {
    let sessions: [FSSession]?
}

struct RawNotesPage: Decodable {
    let notes: [String: FSNote]
    let next_cursor_created_at: String?
    let next_cursor_id: String?
    let has_more: Bool
}

/// Raw shape of `GET /notes/{user_id}/search`'s success response --
/// `{"notes": {note_id: note_data}}`, same per-note fields as RawNotesPage
/// but with no cursor/has_more (search returns every match in one response).
struct RawSearchNotes: Decodable {
    let notes: [String: FSNote]
}

/// Raw shape of one item in `GET /notes/{user_id}/{note_id}/replies` and
/// `GET /groups/{user_id}/{note_id}/{group_id}/replies`'s success response.
/// Both routes return `GroupsManager.fetch_replies()`'s raw DB rows
/// (`SELECT *` minus the primary key -- `DBManager.lookup()` keys its
/// returned dict by `_id`, and `fetch_replies()` then drops that key via
/// `.values()`) rather than the same field-remapping `GET /notes/{user_id}`
/// applies to top-level notes. So there is no `id` in the payload, and the
/// author key is `user_id`, not `user` -- `NetworkService.fetchReplies`
/// remaps both when building each reply's `FSNote`.
struct RawReplyNote: Decodable {
    // Real DB row id (task 20260904-reply-edit-button, backend step 1):
    // `GroupsManager.fetch_replies` now re-attaches the id `lookup()` already
    // had (previously discarded once unwrapped into a flat list) under this
    // key. Optional -- the personal-notes replies route has no server-side
    // implementation yet (out of scope; `NoteDetailView` never calls that
    // branch), so this stays nil there and `fetchReplies` below falls back
    // to a synthesized id rather than crashing a decode that's otherwise
    // still valid.
    let id:             String?
    let user_id:       String?
    let title:          String?
    let text:           String?
    let `public`:       Bool?
    let group_id:       String?
    let is_reply:       Bool?
    let parent_note_id: String?
    let timestamp:      String?
    let created_at:     String?
}
