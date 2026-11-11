// OnboardingModels.swift -- task 20261105-onboarding-redo.
// Pure value types for the hands-on walkthrough: survey topics, the parts they
// expand into, the coach cues inside each part, and the real-action events that
// move a cue forward. No UIKit/SwiftUI state lives here so the plan and
// progression rules are unit-testable (see OnboardingFlowState).
//
// How it fits together:
//   survey picks (Set<OnboardingTopic>) -> OnboardingFlowState.plan(...) ->
//   [OnboardingPart] in fixed order, always ending with .friend.
//   Each part has ordered cues. A cue moves on ONLY when the screen reports the
//   matching OnboardingEvent after the real action succeeded (throw-not-fabricate).
//
// Example: a user who ticks "pray" and "remember" gets
//   [.prayer, .remember, .friend]  (3 parts, friends always counts as one).

import Foundation

/// The four survey options, in the fixed order the walkthroughs run.
enum OnboardingTopic: String, CaseIterable, Codable, Identifiable {
    case devotion, prayer, learn, remember
    var id: String { rawValue }

    var surveyTitle: String {
        switch self {
        case .devotion: return "I struggle to read the Bible consistently."
        case .prayer:   return "I struggle to pray throughout the day."
        case .learn:    return "I want to learn more about the Bible."
        case .remember: return "I struggle with remembering what I learned."
        }
    }

    var part: OnboardingPart {
        switch self {
        case .devotion: return .devotion
        case .prayer:   return .prayer
        case .learn:    return .learn
        case .remember: return .remember
        }
    }
}

/// One walkthrough unit. Topics map 1:1; `.friend` is fixed for everyone.
enum OnboardingPart: String, CaseIterable, Codable, Identifiable {
    case devotion, prayer, learn, remember, friend
    /// Standalone chat tour (task 20261106-chat-tour). Never part of a survey plan.
    case chat
    var id: String { rawValue }

    var label: String {
        switch self {
        case .devotion: return "Daily devotion"
        case .prayer:   return "Prayer"
        case .learn:    return "Learn the Bible"
        case .remember: return "Remember what you learn"
        case .friend:   return "Friends"
        case .chat:     return "Chat"
        }
    }

    /// Recap row title when the part was completed.
    var doneTitle: String {
        switch self {
        case .devotion: return "Scheduled a daily devotion"
        case .prayer:   return "Set a prayer reminder"
        case .learn:    return "Asked your study partner a question"
        case .remember: return "First note, highlight, and chapter jump"
        case .friend:   return "Sent a friend request"
        case .chat:     return "Took the chat tour"
        }
    }

    /// Recap row title and "where to find it later" when skipped.
    var skippedTitle: String {
        switch self {
        case .devotion: return "Daily devotion"
        case .prayer:   return "Prayer reminder"
        case .learn:    return "Study partner"
        case .remember: return "Notes and highlights"
        case .friend:   return "Add a friend"
        case .chat:     return "Chat tour"
        }
    }

    var whereToFind: String {
        switch self {
        case .devotion: return "Account → Scheduled devotions"
        case .prayer:   return "Account → Notification settings"
        case .learn:    return "Chat → Agents"
        case .remember: return "Notes and Bible tabs"
        case .friend:   return "Chat → Friends → +"
        case .chat:     return "Account → Chat tour"
        }
    }

    /// Free users see a "needs a subscription" card instead of these parts.
    var requiresSubscription: Bool { self == .devotion || self == .learn }

    var cues: [OnboardingCue] { OnboardingCue.cues(for: self) }
}

/// Real things that happen in the app. Screens report these only after the
/// underlying action succeeded (a saved devotion, a stored reminder time, ...).
enum OnboardingEvent: String, Codable {
    // devotion
    case devotionSheetOpened, devotionPromptStepReached, devotionRepeatStepReached, devotionSaved
    // prayer
    case notificationSettingsOpened, prayerReminderEnabled, prayerReminderTimeSaved
    // learn
    case agentsSegmentShown, agentChatOpened, agentReplyReceived
    // remember
    case noteEditorOpened, noteSaved, highlightSaved, chapterMenuOpened, chapterNavigated
    // friend
    case addFriendSheetOpened, friendRequestSent
    // chat tour (task 20261106-chat-tour). Reported only after the real action succeeded.
    case friendAvailable, dmOpened, dmMessageSent, messageActionUsed, attachMenuOpened
    case groupsSegmentShown, addGroupSheetOpened, groupCreated, groupThreadOpened, groupInfoOpened
    /// Informational "Next" / "Finish" taps on a coach card (no app action behind them).
    case callIntroSeen, groupInfoReviewed
}

/// Where a cue's coach card is drawn. Sheets and covers sit above the root
/// overlay, so each presents its own card.
enum OnboardingSurface: String, Codable {
    /// Tab screens and pushed screens (everything under ContentView, except Account).
    case root
    /// The Account screen (a tab on phone, a sheet on iPad).
    case accountScreen
    case devotionSheet, agentChatSheet, noteEditor, addFriendSheet
    /// Chat tour: a DM or group conversation sheet, and the new-group sheet.
    case chatThreadSheet, addGroupSheet
    /// Chat tour: the Group info sheet (phone sheet, or inline on iPad).
    case groupInfoSheet
}

/// Which main destination a cue wants showing behind its card.
enum OnboardingDestination: String, Codable {
    case account, chat, notes, bible
}

/// Views that carry a spotlight.
enum OnboardingAnchorID: String, Codable {
    case newDevotionButton, notificationSettingsRow, prayerToggle, prayerTime
    case agentsSegment, studyPartnerRow
    case newNoteButton, bibleVerses, chapterTitle
    case friendsPlusButton
    // chat tour
    case firstFriendRow, groupsSegment, groupsPlusButton, firstGroupRow
    case composerSend, composerAttach, ownMessage, callPill
    case groupNameField, groupHeaderTitle, hostToolsRow
}

struct OnboardingCue: Equatable, Identifiable {
    let id: String
    let surface: OnboardingSurface
    let destination: OnboardingDestination?
    let anchor: OnboardingAnchorID?
    let title: String
    let body: String
    let hint: String?
    /// The event that completes this cue. The last cue's event completes the part.
    let advancesOn: OnboardingEvent
    /// Chat tour only: which of the tour's steps this cue belongs to (one step can
    /// span several cues, e.g. the + button and the New Group sheet). Skip and the
    /// "n of N" counter work on steps.
    var step: Int? = nil
    /// Chat tour only: a gold button on the card ("Next", "Finish") that reports
    /// `advancesOn` for informational cues. Replaces "Skip this step".
    var actionTitle: String? = nil

    static func cues(for part: OnboardingPart) -> [OnboardingCue] {
        switch part {
        case .chat:
            // Fail closed: with no known options the optional features are omitted.
            return chatCues(options: .none)
        case .devotion:
            return [
                .init(id: "devotion.open", surface: .accountScreen, destination: .account, anchor: .newDevotionButton,
                      title: "A devotion that arrives on time",
                      body: "Pick a time and a prompt. Your AI study partner writes it and saves it to your notes, even when the app is closed.",
                      hint: "Tap “New scheduled devotion”", advancesOn: .devotionSheetOpened),
                .init(id: "devotion.time", surface: .devotionSheet, destination: nil, anchor: nil,
                      title: "Choose your time",
                      body: "Morning works for most people. You can change it later.",
                      hint: "Set a time, then tap Next", advancesOn: .devotionPromptStepReached),
                .init(id: "devotion.prompt", surface: .devotionSheet, destination: nil, anchor: nil,
                      title: "We filled in a starter prompt",
                      body: "Keep it, or put it in your own words.",
                      hint: "Edit if you like, then tap Next", advancesOn: .devotionRepeatStepReached),
                .init(id: "devotion.save", surface: .devotionSheet, destination: nil, anchor: nil,
                      title: "Every day is the easiest habit",
                      body: "Daily is already selected. Tap Save and your first devotion arrives tomorrow morning.",
                      hint: "Tap Save", advancesOn: .devotionSaved),
            ]
        case .prayer:
            return [
                .init(id: "prayer.open", surface: .accountScreen, destination: .account, anchor: .notificationSettingsRow,
                      title: "Prayer reminders, on your terms",
                      body: "Choose the time you want a gentle nudge to pray. We only send the ones you turn on.",
                      hint: "Tap Notification settings", advancesOn: .notificationSettingsOpened),
                .init(id: "prayer.toggle", surface: .root, destination: nil, anchor: .prayerToggle,
                      title: "Turn on the Prayer reminder",
                      body: "It sends one nudge a day at the time you choose, in your account time zone.",
                      hint: "Flip the Prayer switch", advancesOn: .prayerReminderEnabled),
                .init(id: "prayer.time", surface: .root, destination: nil, anchor: .prayerTime,
                      title: "Pick when you pray",
                      body: "Set it for midday, or whenever your day tends to run away from you. It saves as soon as you change it.",
                      hint: "Set a time, or tap Keep this time", advancesOn: .prayerReminderTimeSaved),
            ]
        case .learn:
            return [
                .init(id: "learn.agents", surface: .root, destination: .chat, anchor: .agentsSegment,
                      title: "Your personal study partner",
                      body: "Ask it anything about a passage, a word, or an idea you have always wondered about.",
                      hint: "Tap Agents", advancesOn: .agentsSegmentShown),
                .init(id: "learn.open", surface: .root, destination: .chat, anchor: .studyPartnerRow,
                      title: "Open your study partner",
                      body: "Tap it to start a conversation.",
                      hint: "Tap Study partner", advancesOn: .agentChatOpened),
                .init(id: "learn.ask", surface: .agentChatSheet, destination: nil, anchor: nil,
                      title: "Ask a deeper question",
                      body: "Try “What does grace mean, and where does the Bible first use it?” The more specific you are, the deeper it goes.",
                      hint: "Send your question", advancesOn: .agentReplyReceived),
            ]
        case .remember:
            return [
                .init(id: "remember.notes", surface: .root, destination: .notes, anchor: .newNoteButton,
                      title: "Write it down while it is fresh",
                      body: "One line is enough. Add a verse so you can find it again later.",
                      hint: "Tap + to start a note", advancesOn: .noteEditorOpened),
                .init(id: "remember.note", surface: .noteEditor, destination: nil, anchor: nil,
                      title: "Type a line, then save",
                      body: "Your note is saved to your account when you tap Save.",
                      hint: "Type a line, then tap Save", advancesOn: .noteSaved),
                .init(id: "remember.highlight", surface: .root, destination: .bible, anchor: .bibleVerses,
                      title: "Press and hold a verse",
                      body: "Choose Highlight, then pick a color. Use a color for each kind of thing you want to remember.",
                      hint: "Tap & hold, then Highlight", advancesOn: .highlightSaved),
                .init(id: "remember.chapterMenu", surface: .root, destination: .bible, anchor: .chapterTitle,
                      title: "Find your way back",
                      body: "Tap the chapter title to jump to any book. Swipe left or right to move between chapters.",
                      hint: "Tap the chapter title", advancesOn: .chapterMenuOpened),
                .init(id: "remember.navigate", surface: .root, destination: .bible, anchor: .chapterTitle,
                      title: "Pick a chapter",
                      body: "Choose any book and chapter to jump there.",
                      hint: "Choose a chapter", advancesOn: .chapterNavigated),
            ]
        case .friend:
            return [
                .init(id: "friend.open", surface: .root, destination: .chat, anchor: .friendsPlusButton,
                      title: "Study is better together",
                      body: "Add a friend by username. Once they accept, you can message each other and see each other’s highlights across the Bible.",
                      hint: "Tap +", advancesOn: .addFriendSheetOpened),
                .init(id: "friend.send", surface: .addFriendSheet, destination: nil, anchor: nil,
                      title: "Type their username",
                      body: "Ask your friend for theirs. If it doesn’t match anyone, nothing is sent and nothing is revealed.",
                      hint: "Then tap Send Request", advancesOn: .friendRequestSent),
            ]
        }
    }
}

// MARK: Chat tour cues (task 20261106-chat-tour)

/// What this user and server actually have, captured when the tour starts and
/// persisted with it so a kill-and-resume shows the same cues. `.none` (every
/// field false) is the fail-closed default: optional features are omitted, and
/// with no friends the tour offers a skippable "come back" card instead of
/// fabricating a conversation.
struct ChatTourOptions: Codable, Equatable {
    var hasFriends: Bool
    var threads: Bool
    var inviteLink: Bool
    var joinRequests: Bool
    var announcements: Bool
    /// Reactions, replies or pins is on: the "press and hold" step only runs then.
    var messageActions: Bool = false

    static let none = ChatTourOptions(hasFriends: false, threads: false, inviteLink: false,
                                      joinRequests: false, announcements: false, messageActions: false)
}

extension ChatTourOptions {
    private enum CodingKeys: String, CodingKey {
        case hasFriends, threads, inviteLink, joinRequests, announcements, messageActions
    }

    /// Tolerant decode: a key that is missing reads as off (fail closed).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasFriends = try c.decode(Bool.self, forKey: .hasFriends)
        threads = try c.decodeIfPresent(Bool.self, forKey: .threads) ?? false
        inviteLink = try c.decodeIfPresent(Bool.self, forKey: .inviteLink) ?? false
        joinRequests = try c.decodeIfPresent(Bool.self, forKey: .joinRequests) ?? false
        announcements = try c.decodeIfPresent(Bool.self, forKey: .announcements) ?? false
        messageActions = try c.decodeIfPresent(Bool.self, forKey: .messageActions) ?? false
    }
}

/// One recap row of the chat tour: done when `cueID` completed, else open with
/// where to find it later (approved frame E4).
struct ChatTourRecapRow: Equatable {
    let cueID: String
    let title: String
    let whereToFind: String
}

extension OnboardingCue {
    /// Copy and layout follow the Jacey-approved SQUIDWARD frames
    /// (design-approval.md): 7 steps, "n of 7".
    static func chatCues(options o: ChatTourOptions) -> [OnboardingCue] {
        guard o.hasFriends else {
            return [
                .init(id: "chat.needFriend", surface: .root, destination: .chat, anchor: .friendsPlusButton,
                      title: "Add a friend to start chatting",
                      body: "Messages and calls need someone on the other end. Add a friend by username, then we will pick the tour back up.",
                      hint: "Tap + to add a friend", advancesOn: .friendAvailable, step: 1),
            ]
        }
        var infoDoes = ["mute alerts"]
        if o.announcements { infoDoes.append("post announcements") }
        if o.threads { infoDoes.append("keep side conversations in threads") }
        if o.inviteLink { infoDoes.append("create an invite link in Host tools") }
        let infoList = infoDoes.count > 1
            ? infoDoes.dropLast().joined(separator: ", ") + ", and " + infoDoes[infoDoes.count - 1]
            : infoDoes[0]
        let toolsBody = (o.inviteLink
            ? "Create an invite link in Host tools so friends can join with one tap."
            : "Host tools holds your member limit and more.")
            + (o.joinRequests ? " Review join requests there too." : "")
            + " You can mute this chat any time."

        var cues: [OnboardingCue] = [
            .init(id: "chat.openDM", surface: .root, destination: .chat, anchor: .firstFriendRow,
                  title: "Message a friend",
                  body: "Your friends and groups live in Chat. Tap a friend to open your conversation.",
                  hint: "Tap a friend", advancesOn: .dmOpened, step: 1),
            .init(id: "chat.send", surface: .chatThreadSheet, destination: nil, anchor: .composerSend,
                  title: "Say hello",
                  body: "Type a message and send it. It reaches them right away.",
                  hint: "Type a message, then tap send", advancesOn: .dmMessageSent, step: 2),
        ]
        if o.messageActions {
            cues.append(.init(id: "chat.actions", surface: .chatThreadSheet, destination: nil, anchor: .ownMessage,
                              title: "Press and hold a message",
                              body: "React with an emoji, reply to that exact message, or pin it so it is easy to find later.",
                              hint: "Press and hold your message, then pick one", advancesOn: .messageActionUsed, step: 3))
        }
        cues += [
            .init(id: "chat.attach", surface: .chatThreadSheet, destination: nil, anchor: .composerAttach,
                  title: "Share more than words",
                  body: "Tap + to send a photo, a video, a file, or a GIF. Nothing is sent until you choose something.",
                  hint: "Tap +", advancesOn: .attachMenuOpened, step: 4),
            .init(id: "chat.call", surface: .chatThreadSheet, destination: nil, anchor: .callPill,
                  title: "Talk face to face",
                  body: "Tap Call to ring a friend for a voice or video call. We will not ring anyone during the tour.",
                  hint: nil, advancesOn: .callIntroSeen, step: 5, actionTitle: "Next"),
            .init(id: "chat.groupPlus", surface: .root, destination: .chat, anchor: .groupsPlusButton,
                  title: "Start a group",
                  body: "Study with several friends in one conversation. Tap + on the Groups tab to make one.",
                  hint: "Tap +", advancesOn: .addGroupSheetOpened, step: 6),
            .init(id: "chat.groupCreate", surface: .addGroupSheet, destination: nil, anchor: .groupNameField,
                  title: "Start a group",
                  body: "Name it and choose who to invite from your friends. You can add more people later.",
                  hint: "Name it, then tap Create", advancesOn: .groupCreated, step: 6),
            .init(id: "chat.groupOpen", surface: .root, destination: .chat, anchor: .firstGroupRow,
                  title: "Open your group",
                  body: "Your group is in the Groups list. Tap it to open the conversation.",
                  hint: "Tap your group", advancesOn: .groupThreadOpened, step: 7),
            .init(id: "chat.groupInfo", surface: .chatThreadSheet, destination: nil, anchor: .groupHeaderTitle,
                  title: "Open Group info",
                  body: "Tap the group name. You can \(infoList).",
                  hint: "Tap the group name", advancesOn: .groupInfoOpened, step: 7),
            .init(id: "chat.groupTools", surface: .groupInfoSheet, destination: nil, anchor: .hostToolsRow,
                  title: "Make it a home for your group",
                  body: toolsBody,
                  hint: nil, advancesOn: .groupInfoReviewed, step: 7, actionTitle: "Finish"),
        ]
        return cues
    }

    /// "n of N" for a chat-tour cue. N is the length of the full tour for this
    /// user's capabilities, so the no-friends card reads "1 of 7" like the frames.
    static func chatStepProgress(for cue: OnboardingCue, options o: ChatTourOptions) -> (number: Int, total: Int) {
        var full = o
        full.hasFriends = true
        let steps = Array(Set(chatCues(options: full).compactMap(\.step))).sorted()
        let n = (cue.step.flatMap { steps.firstIndex(of: $0) } ?? 0) + 1
        return (n, max(steps.count, 1))
    }

    /// Recap rows (frame E4) present for these options.
    static func chatRecapRows(options o: ChatTourOptions) -> [ChatTourRecapRow] {
        var full = o
        full.hasFriends = true
        let ids = Set(chatCues(options: full).map(\.id))
        let all: [ChatTourRecapRow] = [
            .init(cueID: "chat.send", title: "Messaged a friend", whereToFind: "Chat → Friends"),
            .init(cueID: "chat.actions", title: "Reacted, replied or pinned", whereToFind: "Press and hold a message"),
            .init(cueID: "chat.attach", title: "Shared a photo, file or GIF", whereToFind: "The + beside the message box"),
            .init(cueID: "chat.groupCreate", title: "Started a group", whereToFind: "Chat → Groups → +"),
            .init(cueID: "chat.groupTools", title: "Set up Group info", whereToFind: "Tap the group name"),
        ]
        return all.filter { ids.contains($0.cueID) }
    }
}
