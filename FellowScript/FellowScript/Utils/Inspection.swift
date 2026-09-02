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

// Gated to Debug only (task 20260902-ios-deployment-target-lower): this type
// exists purely as ViewInspector test-support scaffolding and has no
// production behavior — it should never have been compiled into the shipping
// Release binary in the first place. Separately, with IPHONEOS_DEPLOYMENT_TARGET
// lowered to 18.0, Release's whole-module -O build hits a deterministic Swift
// 6.3.3 compiler crash (EarlyPerfInliner SIL pass) specifically on this
// generic class's implicit deinit (`@$s12FellowScript10InspectionCfD`) —
// reproduced consistently, isolated via A/B (crashes only with both the
// lowered deployment target AND this file's Release compilation present;
// reverting either one independently avoids the crash). Excluding it from
// Release removes the crashing symbol from that compilation unit entirely,
// which is correct on both counts: it's test-only code that has no business
// shipping, and doing so also sidesteps the toolchain bug. Debug builds (all
// app runs, and both FellowScriptTests/FellowScriptUITests, which build
// against the Debug configuration per the shared scheme) are unaffected.
#if DEBUG
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
#endif
