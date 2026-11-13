// VerseFrameProbe.swift -- task 20261112-verse-ask-ai (step 5).
// Lets the reader learn a verse row's on-screen frame at the moment the user
// picks "Ask AI", without any per-scroll state work. Each VerseRow carries a
// zero-size probe UIView registered here; the frame is converted to window
// coordinates only when asked. Nothing is published, so scrolling and layout
// of the verse list are untouched.

import SwiftUI
import UIKit

@MainActor
final class VerseFrameStore {
    private final class Box { weak var view: UIView?; init(_ v: UIView) { view = v } }
    private var boxes: [Int: Box] = [:]

    func register(verse: Int, view: UIView) { boxes[verse] = Box(view) }

    /// Window-space frame of the verse row, or nil if it is no longer on screen.
    func frame(verse: Int) -> CGRect? {
        guard let v = boxes[verse]?.view, v.window != nil else { return nil }
        return v.convert(v.bounds, to: nil)
    }
}

/// Fills its host (placed as a `.background`), so its bounds equal the verse row.
struct VerseFrameProbe: UIViewRepresentable {
    let verse: Int
    let store: VerseFrameStore

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        v.isAccessibilityElement = false
        store.register(verse: verse, view: v)
        return v
    }
    func updateUIView(_ v: UIView, context: Context) { store.register(verse: verse, view: v) }
}
