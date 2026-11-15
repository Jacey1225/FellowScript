// NoteDraftGuard.swift — task 20261115-ipad-askai-notegate (item 2).
// Pure, UI-free rules for the unsaved-note gate so they can be unit tested:
//   1. the dirty rule (draft vs. the baseline captured when the editor opened),
//   2. the proceed/confirm decision for a user action that would drop the draft,
//   3. whether a workspace layout change would unmount the Notes tab's editor.
// NoteEditorView reports `dirty` upward through NoteDraftDirtyKey; WorkspaceView
// and NotesListView route every destructive action through `decision`.

import SwiftUI

/// Comparable view of what the user can change in the editor. Body is compared
/// as plain text (tags stripped, whitespace collapsed) because the rich-text
/// view re-serializes HTML on the first keystroke, so raw HTML would read as
/// "changed" for any edit. A formatting-only change (bold, color) with
/// identical text is therefore not counted as a modification.
struct NoteDraftSnapshot: Equatable {
    var title: String
    var bodyText: String
    var verses: [String]
    var isPublic: Bool
}

enum NoteDraftGuard {

    enum Decision: Equatable {
        /// Nothing to lose: run the action now.
        case proceed
        /// A non-empty / modified draft would be dropped: ask Keep editing vs Discard.
        case confirm
    }

    static func snapshot(title: String, bodyHTML: String, verses: [String], isPublic: Bool) -> NoteDraftSnapshot {
        NoteDraftSnapshot(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            bodyText: normalizedBody(bodyHTML),
            verses: verses,
            isPublic: isPublic
        )
    }

    static func normalizedBody(_ html: String) -> String {
        stripHTMLTags(html)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// A draft is dirty when it differs from the baseline taken at editor init.
    /// New empty note: baseline == empty, so an untouched editor is clean.
    /// Untouched verse prefill: baseline already contains the prefill, so clean.
    /// Existing note: dirty only when modified relative to the saved version.
    static func isDirty(baseline: NoteDraftSnapshot, current: NoteDraftSnapshot) -> Bool {
        baseline != current
    }

    static func decision(dirty: Bool) -> Decision { dirty ? .confirm : .proceed }

    /// Whether the Notes tab (and so its inline editor) is still mounted, in the
    /// same dock and as that dock's active tab, after a layout change. The dock
    /// body is `.id(tab)`, so any other outcome recreates the view and loses
    /// its @State draft.
    static func editorSurvives(before: WorkspaceDockLayout, after: WorkspaceDockLayout,
                               tab: WorkspaceTab = .notes) -> Bool {
        guard let dockBefore = before.dock(of: tab), let dockAfter = after.dock(of: tab),
              dockBefore == dockAfter else { return false }
        return before.activeTab(in: dockBefore) == tab && after.activeTab(in: dockAfter) == tab
    }

    /// Decision for a workspace layout change while the Notes editor is `dirty`.
    static func decision(dirty: Bool, before: WorkspaceDockLayout, after: WorkspaceDockLayout,
                         tab: WorkspaceTab = .notes) -> Decision {
        guard dirty else { return .proceed }
        return editorSurvives(before: before, after: after, tab: tab) ? .proceed : .confirm
    }
}

/// True while an inline (iPad) NoteEditorView holds a non-empty or modified draft.
struct NoteDraftDirtyKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
