// Guideline 1.2: report-a-user sheet, presented from a friend row's swipe action
// in ChatRootView. Submits POST /reports/ (content_type: "user") via
// DataServiceProtocol.reportUser — the developer is emailed immediately and
// commits to acting within 24 hours (see backend/moderation/admin_actions.py).

import SwiftUI

private let reportReasons: [(value: String, label: String)] = [
    ("harassment", "Harassment or abusive behavior"),
    ("hate_speech", "Hate speech or discrimination"),
    ("sexual_content", "Sexually explicit or inappropriate content"),
    ("spam", "Spam or scam"),
    ("other", "Other"),
]

struct ReportUserSheet: View {
    let contact: FSContact
    let onSubmit: (_ reason: String, _ detail: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reason = "harassment"
    @State private var detail = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Reason") {
                    ForEach(reportReasons, id: \.value) { r in
                        Button(action: { reason = r.value }) {
                            HStack {
                                Text(r.label).foregroundColor(Theme.parchment)
                                Spacer()
                                if reason == r.value {
                                    Image(systemName: "checkmark").foregroundColor(Theme.gold)
                                }
                            }
                        }
                    }
                }
                .listRowBackground(Theme.cardBg)

                Section("Additional details (optional)") {
                    TextEditor(text: $detail)
                        .frame(minHeight: 80)
                        .foregroundColor(Theme.parchment)
                }
                .listRowBackground(Theme.cardBg)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bgPage)
            .navigationTitle("Report \(contact.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(Theme.textGoldMuted)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Submit") {
                        onSubmit(reason, detail)
                        dismiss()
                    }
                    .foregroundColor(.red)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
