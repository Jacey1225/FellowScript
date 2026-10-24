// FSFormScaffold.swift
// Screen skeleton for forms (spec 2.1): nav bar with close X + centered title,
// optional stepper rail, scroll area on the warm page background, optional
// form-level card above, pinned action bar. Handles the discard guard
// (interactiveDismissDisabled while dirty + confirmationDialog on X).

import SwiftUI

struct FSFormScaffold<Content: View, Banner: View, Bar: View>: View {
    let title: String
    var dirty: Bool = false
    var rail: AnyView? = nil
    var onClose: () -> Void
    @ViewBuilder var banner: () -> Banner
    @ViewBuilder var content: () -> Content
    @ViewBuilder var bar: () -> Bar

    @State private var confirmDiscard = false

    var body: some View {
        ZStack {
            Color.clear.warmBloomBackground()
            VStack(spacing: 0) {
                navBar
                if let rail { rail }
                ScrollView {
                    VStack(spacing: 16) { content() }
                        .padding(.horizontal, 16)
                        .padding(.top, rail == nil ? 24 : 32)
                        .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                // Content fades out above the flush bar (mask only, adds no color).
                .mask(VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 24)
                })
                banner().padding(.horizontal, 16).padding(.bottom, 8)
                bar()
            }
        }
        .interactiveDismissDisabled(dirty)
        .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive, action: onClose)
            Button("Keep editing", role: .cancel) {}
        }
    }

    private var navBar: some View {
        ZStack {
            Text(title).font(.fsSheetTitle).foregroundColor(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Button { if dirty { confirmDiscard = true } else { onClose() } } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundColor(Theme.gold)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.cardGlassGray))
                        .overlay(Circle().strokeBorder(Theme.borderGray, lineWidth: 1))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
    }
}

extension FSFormScaffold where Banner == EmptyView {
    init(title: String, dirty: Bool = false, rail: AnyView? = nil, onClose: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content, @ViewBuilder bar: @escaping () -> Bar) {
        self.title = title; self.dirty = dirty; self.rail = rail; self.onClose = onClose
        self.banner = { EmptyView() }; self.content = content; self.bar = bar
    }
}
