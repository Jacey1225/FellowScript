# FellowScript iOS

SwiftUI port of the FellowScript web frontend. iOS 17+, portrait-primary, no UIKit bridging.

## Project structure

```
ios/FellowScript/
├── FellowScriptApp.swift          Entry point — injects AppState EnvironmentObject
├── ContentView.swift              Root: Onboarding cover → Auth → 5-tab TabView
├── Theme/
│   └── Theme.swift                ALL color tokens, font helpers, corner radii, spacing
├── Models/
│   └── Models.swift               FSUser, FSNote, FSHighlight, FSMessage, FSAgent, ...
├── Services/
│   ├── AppState.swift             @EnvironmentObject — auth state, persisted to AppStorage
│   ├── MockDataService.swift      Stub data (renders without backend)
│   └── NetworkService.swift       Real REST/WebSocket client (swap into AppState)
├── Onboarding/
│   └── OnboardingView.swift       Paginated TabView carousel + CTA page
├── Auth/
│   └── AuthView.swift             Sign In / Create Account toggle form
├── Dashboard/
│   └── DashboardView.swift        4 widget cards: Recent Note, Community, Highlight, Agent
├── Bible/
│   └── BibleReaderView.swift      Book/chapter sheet, verse long-press context menu, highlights, bookmarks
├── Notes/
│   ├── NotesListView.swift        Notes + Highlights tabs, swipe-to-delete, filter sheet
│   └── NoteEditorView.swift       Title + body, format toolbar, verse tags, public toggle
├── Chat/
│   ├── ChatRootView.swift         Friends / Groups / Agents segments
│   ├── ChatThreadView.swift       Message bubbles, session banner, new session sheet
│   └── AgentChatView.swift        AI chat thread with typing indicator
└── Account/
    └── AccountView.swift          Stats, edit profile, friend requests, agents, danger zone
```

## How to run

1. Open `ios/FellowScript.xcodeproj` (create one via Xcode → File → New Project, then drag these files in, targeting iOS 17).
2. Build and run on Simulator or device.
3. The app runs entirely on `MockDataService` by default — no backend needed.
4. To connect to the live server, replace `MockDataService.shared` with `NetworkService.shared` in `AppState.init(service:)`.

## Design tokens → Theme.swift

| CSS variable | Swift constant |
|---|---|
| `--gold #C8861A` | `Theme.gold` |
| `--parchment #F4E4C1` | `Theme.parchment` |
| `--ink #1A100A` | `Theme.ink` |
| `--bible-bg #231610` | `Theme.bibleBg` |
| `--bible-text #E8D9BB` | `Theme.bibleText` |
| `fontFamily: Lora, serif` | `Font.lora(_:)` → Georgia |
| `fontFamily: Playfair Display` | `Font.playfair(_:)` → Georgia-Bold |

## Source mapping

| Screen | JSX source |
|---|---|
| Onboarding carousel | `Dashboard.jsx` FEATURES array + hero copy |
| Auth | `SignIn.jsx` |
| Dashboard widgets | `Reader.jsx` + `NotesSidebar.jsx` + `useAgentChat.js` |
| Bible Reader | `Reader.jsx` + `useBible.js` + `useHighlights.js` + `useBookmarks.js` + `BibleNavigator.jsx` |
| Notes List | `NotesSidebar.jsx` (NoteCard, HighlightCard, FilterPanel) |
| Note Editor | `NotesSidebar.jsx` (NoteEditor component) |
| Chat Root | `MessagingSidebar.jsx` |
| Chat Thread | `MessagingSidebar.jsx` (ChatView) + `SessionCreator.jsx` |
| Agent Chat | `useAgentChat.js` + Reader.jsx AgentChatPanel |
| Account | `Account.jsx` |
