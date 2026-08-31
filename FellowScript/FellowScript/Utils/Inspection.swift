// Inspection.swift — ViewInspector's documented "Approach #2" test seam
// (guide.md, "Views using @State, @Environment or @EnvironmentObject").
//
// Added for task 20260828-note-reply-continuation-ios, testing step (step 4),
// to cover NoteDetailView's async `.task(id:)`-driven reply-loading state
// (`replies`/`repliesLoaded`, set only after `loadReplies()`'s await
// resolves). The existing `didAppear` seam already on NoteDetailView (added
// by the frontend gate, ViewInspector's "Approach #1") only fires once, at
// `.onAppear`, before an async `.task` has had a chance to complete — it
// cannot observe state that settles after a real time gap. This file adds
// the small, standard, behaviorally-inert building block Approach #2 needs
// (`sut.inspection.inspect(after:)`) instead: `Inspection<V>` carries no
// production behavior of its own (a Combine subject + a callback registry),
// and a view only reacts to it if something calls `inspection.inspect(...)`
// in a test — inert otherwise, exactly like `didAppear`.
//
// Intentionally `internal` (not private) so any SwiftUI view in this target
// can opt in with the same two-line pattern the guide documents:
//   internal let inspection = Inspection<Self>()
//   .onReceive(inspection.notice) { self.inspection.visit(self, $0) }

import Combine
import SwiftUI

internal final class Inspection<V> {
    let notice = PassthroughSubject<UInt, Never>()
    var callbacks = [UInt: (V) -> Void]()

    func visit(_ view: V, _ line: UInt) {
        if let callback = callbacks.removeValue(forKey: line) {
            callback(view)
        }
    }
}
