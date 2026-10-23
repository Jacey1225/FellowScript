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
    @State private var reason: String? = "harassment"
    @State private var detail = ""

    var body: some View {
        FSFormScaffold(
            title: "Report \(contact.name)",
            dirty: !detail.isEmpty,
            onClose: { dismiss() },
            content: {
                FSFormCard(title: "Reason") {
                    FSRadioList(options: reportReasons.map { (id: $0.value, title: $0.label, helper: nil as String?) },
                                selection: $reason)
                }
                FSFormCard(title: "Details") {
                    FSField(label: "Additional details", optional: true, text: $detail,
                            helper: "Reports are private.", maxLength: 500, multiline: true, minLines: 4)
                }
            },
            bar: {
                // A report is a safety action, not a destructive one (spec D16): primary stays gold.
                FSPinnedActionBar(secondaryTitle: "Cancel", onSecondary: { dismiss() },
                                  primaryTitle: "Send report", primaryDimmed: reason == nil,
                                  onPrimary: {
                                      guard let reason else { return }
                                      onSubmit(reason, detail)
                                      dismiss()
                                  })
            }
        )
        .dismissesKeyboardOnScrollAndTap()
        .preferredColorScheme(.dark)
    }
}
