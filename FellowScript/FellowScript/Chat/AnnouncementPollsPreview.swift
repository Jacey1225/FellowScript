// AnnouncementPollsPreview.swift — DEBUG-only screenshot seam (task 20261024-announcement-polls).
// Launch with "UI-TESTING-POLLS-PREVIEW" (+ "polls-detail", "polls-closed" or "polls-form") to render the poll
// voting card and the poll builder against local fixtures, no server and no account. Not compiled into release builds.

#if DEBUG
import SwiftUI

struct RootOrPollsPreview: View {
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("UI-TESTING-POLLS-PREVIEW") {
            AnnouncementPollsPreview()
        } else {
            ContentView()
        }
    }
}

private struct AnnouncementPollsPreview: View {
    private let args = ProcessInfo.processInfo.arguments
    @State private var item: FSGroupAnnouncement = AnnouncementPollsPreview.fixture(closed: ProcessInfo.processInfo.arguments.contains("polls-closed"))
    @State private var extras: AnnouncementExtrasDraft = {
        var e = AnnouncementExtrasDraft(from: nil)
        e.pollOn = true
        e.pollQuestion = "Which night works best for study?"
        e.pollOptions = ["Tuesday", "Wednesday", ""]
        e.pollHasCloseTime = true
        return e
    }()
    @State private var busy = false

    static func fixture(closed: Bool) -> FSGroupAnnouncement {
        let poll = FSAnnouncementPoll(
            question: "Which night works best for study?", multiple: false, closes_at: nil, closed: closed, total_voters: 9,
            options: [FSPollOption(id: "a", label: "Tuesday", votes: 4, percent: 44),
                      FSPollOption(id: "b", label: "Wednesday", votes: 3, percent: 33),
                      FSPollOption(id: "c", label: "Friday", votes: 2, percent: 22)],
            my_votes: closed ? ["b"] : [])
        return FSGroupAnnouncement(
            id: "p1", group_id: "g1", creator_id: "u2", creator_username: "sarah", title: "Study night schedule",
            description: "We're picking a new weekly night. Vote below and the most popular one wins.",
            banner_url: nil, publish_at: "2026-10-23T12:00:00+00:00", created_at: "2026-10-23T12:00:00+00:00",
            updated_at: "2026-10-23T12:00:00+00:00", published: true, can_edit: closed ? true : false, poll: poll)
    }

    /// Local stand-in for the server: recomputes counts from the pretend voters.
    private func tally(_ p: FSAnnouncementPoll, mine: [String]) -> FSAnnouncementPoll {
        var base: [String: Int] = ["a": 4, "b": 3, "c": 2]
        for id in mine { base[id, default: 0] += 1 }
        let total = 9 + (mine.isEmpty ? 0 : 1)
        var out = p
        out.total_voters = total
        out.my_votes = mine
        out.options = p.options.map { o in
            var n = o; n.votes = base[o.id] ?? 0; n.percent = total == 0 ? 0 : Int((Double(n.votes) / Double(total) * 100).rounded()); return n
        }
        return out
    }

    private var actions: AnnouncementPollActions {
        AnnouncementPollActions(
            vote: { ids in var u = item; u.poll = tally(item.poll!, mine: ids); item = u; return u },
            retract: { var u = item; u.poll = tally(item.poll!, mine: []); item = u; return u },
            close: item.can_edit ? { var u = item; u.poll?.closed = true; item = u; return u } : nil)
    }

    var body: some View {
        NavigationStack {
            if args.contains("polls-form") {
                ScrollView {
                    AnnouncementExtrasSection(extras: $extras, linksOn: false, galleryOn: false, paymentsOn: false, rsvpOn: false,
                                              locationOn: false, pollsOn: true, saving: false, busy: $busy,
                                              upload: { _ in "" }, onChange: {})
                        .padding(16)
                }
                .background { Color.clear.warmBloomBackground() }
                .navigationTitle("New announcement").navigationBarTitleDisplayMode(.inline)
            } else {
                GroupAnnouncementDetailView(item: item, onEdit: {}, onDelete: {}, pollActions: actions)
                    .environmentObject(AppState())
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
