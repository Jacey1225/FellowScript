// FSPrivacyShield.swift
// Blurs sensitive form content while the app is not active (spec 9.1.6) so the
// app-switcher snapshot never shows passwords, account numbers or typed confirms.

import SwiftUI

private struct FSPrivacyShield: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    func body(content: Content) -> some View {
        content
            .blur(radius: scenePhase == .active ? 0 : 24)
            .overlay {
                if scenePhase != .active { Theme.bgPage.opacity(0.85).ignoresSafeArea() }
            }
    }
}

extension View {
    func fsPrivacyShield() -> some View { modifier(FSPrivacyShield()) }
}
