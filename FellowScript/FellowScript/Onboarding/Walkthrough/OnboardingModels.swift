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
    var id: String { rawValue }

    var label: String {
        switch self {
        case .devotion: return "Daily devotion"
        case .prayer:   return "Prayer"
        case .learn:    return "Learn the Bible"
        case .remember: return "Remember what you learn"
        case .friend:   return "Friends"
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
        }
    }

    var whereToFind: String {
        switch self {
        case .devotion: return "Account → Scheduled devotions"
        case .prayer:   return "Account → Notification settings"
        case .learn:    return "Chat → Agents"
        case .remember: return "Notes and Bible tabs"
        case .friend:   return "Chat → Friends → +"
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
}

/// Where a cue's coach card is drawn. Sheets and covers sit above the root
/// overlay, so each presents its own card.
enum OnboardingSurface: String, Codable {
    /// Tab screens and pushed screens (everything under ContentView, except Account).
    case root
    /// The Account screen (a tab on phone, a sheet on iPad).
    case accountScreen
    case devotionSheet, agentChatSheet, noteEditor, addFriendSheet
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

    static func cues(for part: OnboardingPart) -> [OnboardingCue] {
        switch part {
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
