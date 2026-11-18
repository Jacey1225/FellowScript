// WebCheckoutViews.swift — task 20261117-web-only-payments (Option A), iOS/iPad.
//
// US App Store storefront only (WebCheckoutGate): the "Subscribe on the web"
// button and the seat picker that goes with it. Non-US and unknown storefronts
// never render anything from this file; they keep the StoreKit UI unchanged.
// Prices come from the server quote only (never computed or hardcoded here).

import SwiftUI

// MARK: - Button

/// Full-width gold button that opens the website checkout in the system browser.
/// Used by the Account card, the upgrade prompt and the post-tour prompt.
struct WebCheckoutLinkButton: View {
    var seats: Int
    var identifier: String = "webCheckoutSubscribe"
    var onOpen: (() -> Void)? = nil
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(WebCheckoutPolicy.checkoutURL(seats: seats))
            onOpen?()
        } label: {
            HStack(spacing: 8) {
                Text("Subscribe on the web")
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "arrow.up.right.square").accessibilityHidden(true)
            }
            .foregroundColor(Theme.ink)
            .padding(.horizontal, Theme.spacingMD).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(LinearGradient(colors: [Theme.gold, Theme.goldLight],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityLabel("Subscribe on the web")
        .accessibilityHint("Opens fellowscript.com in your browser")
        .accessibilityIdentifier(identifier)
    }
}

/// The only explanation shown next to the web button.
struct WebCheckoutFootnote: View {
    var body: some View {
        Text("Opens fellowscript.com in your browser. Payment is handled there, not by Apple.")
            .font(.caption2)
            .foregroundColor(Theme.textMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("webCheckoutFootnote")
    }
}

// MARK: - Account card section (US, no plan)

struct WebCheckoutSection: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = WebCheckoutQuoteModel()
    @State private var seatText = "1"
    @FocusState private var seatFieldFocused: Bool

    var body: some View {
        Group {
            if model.blockedByApple {
                WebCheckoutAppleManagedNotice()
            } else {
                content
            }
        }
        .task {
            model.configure(service: appState.service)
            if model.phase == .idle { model.request(seats: 1, immediate: true) }
        }
        .onChange(of: model.quote) { _, q in
            if let q, !seatFieldFocused { seatText = "\(q.seats)" }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            HStack(spacing: Theme.spacingMD) {
                ZStack {
                    Circle().fill(Theme.gold.opacity(0.12)).frame(width: 36, height: 36)
                    Image(systemName: "person.3.fill").foregroundColor(Theme.gold)
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Group plan").font(.body).foregroundColor(Theme.parchment)
                    priceLines
                }
                Spacer(minLength: 0)
            }

            if let lo = model.minSeats, let hi = model.maxSeats {
                seatRow(range: lo...hi)
            }

            WebCheckoutLinkButton(seats: model.seats)
            WebCheckoutFootnote()

            HStack(spacing: 6) {
                Link("Privacy Policy", destination: URL(string: "https://fellowscript.com/#/privacy")!)
                Text("·").foregroundColor(Theme.textMuted)
                Link("Terms of Use", destination: URL(string: "https://fellowscript.com/#/terms")!)
            }
            .font(.caption2)
            .foregroundColor(Theme.textGoldMuted)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .contain)
        }
    }

    // Price + sentence. One combined VoiceOver element for the price.
    @ViewBuilder private var priceLines: some View {
        if let q = model.quote, let total = model.totalCents {
            Text("\(q.seats) seat\(q.seats == 1 ? "" : "s") - \(WebCheckoutFormat.price(cents: total))/mo")
                .font(.subheadline).foregroundColor(Theme.textGoldMuted)
                .opacity(model.phase == .loading ? 0.5 : 1)
                .overlay(alignment: .trailing) {
                    if model.phase == .loading { ProgressView().controlSize(.small).tint(Theme.gold).offset(x: 24) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(WebCheckoutFormat.spokenPrice(seats: q.seats, cents: total))
                .accessibilityValue(model.phase == .loading ? "Updating price" : "")
                .accessibilityIdentifier("webCheckoutPrice")
            if let sentence = WebCheckoutFormat.perSeatSentence(q) {
                Text(sentence).font(.caption).foregroundColor(Theme.textMuted)
            }
        } else if model.phase == .failed {
            Text("See price on the website.")
                .font(.subheadline).foregroundColor(Theme.textMuted)
                .accessibilityIdentifier("webCheckoutPrice")
        } else {
            // Reserved height while the first quote loads (no layout jump).
            Text(" ").font(.subheadline).overlay { ProgressView().controlSize(.small).tint(Theme.gold) }
                .accessibilityLabel("Loading price")
        }
    }

    @ViewBuilder private func seatRow(range: ClosedRange<Int>) -> some View {
        let label = Text("Seats").font(.footnote.weight(.semibold)).foregroundColor(Theme.textPrimary)
        let controls = HStack(spacing: 12) {
            stepButton("minus", enabled: model.seats > range.lowerBound) { commit(model.seats - 1, range) }
            TextField("Seats", text: $seatText)
                .keyboardType(.numberPad)
                .focused($seatFieldFocused)
                .multilineTextAlignment(.center)
                .font(.body.weight(.semibold)).foregroundColor(Theme.textPrimary)
                .frame(minHeight: Theme.formFieldHeight)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fieldFill))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.fieldBorder, lineWidth: 1))
                .onChange(of: seatText) { _, t in
                    let digits = t.filter(\.isNumber)
                    if digits != t { seatText = digits; return }
                    if let n = Int(digits), n >= range.lowerBound, n <= range.upperBound, n != model.seats { model.request(seats: n) }
                }
                .onChange(of: seatFieldFocused) { _, focused in
                    if !focused { commit(Int(seatText) ?? model.seats, range) }
                }
                .accessibilityLabel("Seats")
                .accessibilityValue("\(model.seats) seat\(model.seats == 1 ? "" : "s")")
                .accessibilityIdentifier("webCheckoutSeatStepper")
            stepButton("plus", enabled: model.seats < range.upperBound) { commit(model.seats + 1, range) }
        }
        // Label always sits above the controls, so accessibility text sizes never
        // squeeze the stepper beside it.
        VStack(alignment: .leading, spacing: 6) { label; controls }
    }

    private func commit(_ n: Int, _ range: ClosedRange<Int>) {
        let clamped = min(max(n, range.lowerBound), range.upperBound)
        seatText = "\(clamped)"
        model.request(seats: clamped)
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.semibold))
                .foregroundColor(Theme.gold).frame(width: 44, height: 44)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(symbol == "plus" ? "Add a seat" : "Remove a seat")
    }
}

// MARK: - Active Apple plan (US)

/// Shown instead of any purchase UI while an Apple plan is active.
struct WebCheckoutAppleManagedNotice: View {
    @ObservedObject private var store = StoreKitManager.shared
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            Text("To change seats, manage your plan in Apple Settings. Your plan renews through Apple.")
                .font(.footnote).foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("appleManagedNotice")
            Button { Task { await store.showManageSubscriptions() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                    Text("Manage Subscription").font(.footnote)
                }
                .foregroundColor(Theme.gold)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .frame(minHeight: 44)
                .overlay(Capsule().stroke(Theme.borderGold, lineWidth: 1))
            }
        }
    }
}
