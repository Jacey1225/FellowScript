# File Tree — 20260904-frontend-arch-sweep

## Scope note (updated — scope expanded on re-entry)

The request scoped this sweep to **frontend code, web and iOS**. The initial pass (see prior version of this note, superseded below) interpreted "frontend" literally as the two roots explicitly named in the earliest framing of the request:

1. `FellowScript/FellowScript/` (iOS SwiftUI app target), **excluding** `FellowScriptTests/` and `FellowScriptUITests/`.
2. `frontend/src/` (React web app source, the Vite/React SPA).

That pass flagged as an explicit assumption that it was *excluding* a third surface also living under `frontend/`: the legacy static tree (`frontend/account.html`, `frontend/reader.html`, `frontend/signin.html`, `frontend/css/`, `frontend/js/`), reasoning that `frontend/dist/` (Vite build output) suggested `src/` was the sole actively-built app and the legacy tree might be dead code left over from a prior architecture.

**That assumption has since been confirmed wrong and corrected on this re-entry.** The legacy static tree is actively maintained — recent commits this week touched `frontend/js/` and `frontend/css/` for notes-UI fixes — and per this project's own deploy docs, nginx serves the legacy tree's HTML/CSS/JS directly, separately from (not superseded by) the Vite/React app. Since the request asked for "entire frontend code, web and iOS," this legacy tree is now included as a third reviewable root. This inventory addition does not touch anything already inventoried under `FellowScript/FellowScript/` or `frontend/src/` — those stand as previously recorded.

Repo is a git working tree; the legacy-tree addition was built the same way as the original pass — `git ls-files` (respects `.gitignore`), cross-checked with `find` directly on `frontend/css/` and `frontend/js/` and `git status --porcelain` for untracked files (none found; all 21 added files are tracked, none in-progress/uncommitted).

## Directory diagram

```
FellowScript/FellowScript/                          [iOS app target — reviewable]
├── Account/
│   ├── AccountView.swift                           swift · 2174
│   ├── BlockedUsersView.swift                      swift · 80
│   ├── EventSetupSheet.swift                       swift · 507
│   └── MfaSheets.swift                             swift · 111
├── Assets.xcassets/                                [asset catalog — Contents.json excluded as metadata, images excluded as binary]
│   ├── Contents.json                                (excluded: asset-catalog metadata)
│   ├── AppIcon.appiconset/
│   │   ├── Contents.json                            (excluded: asset-catalog metadata)
│   │   └── fellowscript-app-icon-1024.png           (excluded: binary image)
│   ├── FellowScriptMark.imageset/
│   │   ├── Contents.json                            (excluded: asset-catalog metadata)
│   │   └── fellowscript-mark-1024.png               (excluded: binary image)
│   └── OnboardingTour/
│       ├── Contents.json                            (excluded: asset-catalog metadata)
│       ├── tour-account.imageset/            {Contents.json, tour-account.png}            (excluded)
│       ├── tour-add-friend.imageset/         {Contents.json, tour-add-friend.png}          (excluded)
│       ├── tour-ai-agent.imageset/           {Contents.json, tour-ai-agent.png}             (excluded)
│       ├── tour-bible-nav.imageset/          {Contents.json, tour-bible-nav.png}            (excluded)
│       ├── tour-create-group.imageset/       {Contents.json, tour-create-group.png}         (excluded)
│       ├── tour-create-note.imageset/        {Contents.json, tour-create-note.png}          (excluded)
│       ├── tour-dashboard.imageset/          {Contents.json, tour-dashboard.png}             (excluded)
│       ├── tour-friend-chat.imageset/        {Contents.json, tour-friend-chat.png}           (excluded)
│       ├── tour-group-notes.imageset/        {Contents.json, tour-group-notes.png}           (excluded)
│       ├── tour-group-session.imageset/      {Contents.json, tour-group-session.png}         (excluded)
│       ├── tour-heartbeat.imageset/          {Contents.json, tour-heartbeat.png}              (excluded)
│       └── tour-highlights.imageset/         {Contents.json, tour-highlights.png}             (excluded)
├── Auth/
│   ├── AppleAuthSession.swift                      swift · 74
│   ├── AuthView.swift                              swift · 473
│   ├── CompleteProfileView.swift                   swift · 101
│   ├── ForgotPasswordView.swift                    swift · 109
│   ├── GoogleAuthSession.swift                     swift · 137
│   ├── MfaVerifyView.swift                         swift · 96
│   └── TermsReacceptView.swift                     swift · 77
├── Bible/
│   ├── BibleReaderView.swift                       swift · 1035
│   ├── bible.json                                   (excluded: 4.2MB translation data blob)
│   └── bible.json.bak-20260712-232858               (excluded: dated backup file)
├── Chat/
│   ├── AgentChatView.swift                         swift · 474
│   ├── ChatRootView.swift                          swift · 1002
│   ├── ChatThreadView.swift                        swift · 1449
│   ├── ChimeCallView.swift                         swift · 505
│   ├── ChimeModels.swift                           swift · 28
│   ├── ChipToggle.swift                            swift · 108
│   ├── MessageAttachments.swift *untracked*         swift · 682
│   ├── MessageGroupRow.swift                       swift · 290
│   ├── PillButton.swift                            swift · 69
│   ├── ReportUserSheet.swift                       swift · 71
│   └── SegmentedDurationControl.swift              swift · 71
├── ContentView.swift                               swift · 179
├── Dashboard/
│   ├── DashboardComponents.swift                   swift · 785
│   ├── DashboardView.swift                         swift · 313
│   └── FloatingTabBar.swift                        swift · 74
├── FellowScript.entitlements                       entitlements (config) · 12
├── FellowScript.storekit                           storekit (config) · 225
├── FellowScriptApp.swift                           swift · 98
├── Fonts/                                          [excluded: binary font files + license text]
│   ├── Inter-Bold.ttf                               (excluded: binary font)
│   ├── Inter-Regular.ttf                            (excluded: binary font)
│   ├── Inter-SemiBold.ttf                           (excluded: binary font)
│   ├── NOTICE.md                                    (excluded: license doc)
│   ├── OFL-Inter.txt                                (excluded: license doc)
│   ├── OFL-PlayfairDisplay.txt                       (excluded: license doc)
│   ├── PlayfairDisplay-Bold.ttf                     (excluded: binary font)
│   ├── PlayfairDisplay-Italic.ttf                   (excluded: binary font)
│   ├── PlayfairDisplay-Regular.ttf                  (excluded: binary font)
│   └── PlayfairDisplay-SemiBold.ttf                 (excluded: binary font)
├── Info.plist                                      plist (config) · 83
├── LoadingScreen/
│   ├── LoadingScreenView.swift                     swift · 154
│   └── loading-screen.mov                           (excluded: binary video)
├── Models/
│   └── Models.swift                                swift · 730
├── Notes/
│   ├── NoteEditorView.swift                        swift · 614
│   └── NotesListView.swift                         swift · 2024
├── Onboarding/
│   ├── OnboardingView.swift                        swift · 716
│   └── TOUR_SCREENSHOT_CAPTURE.md                   (excluded: doc)
├── PrivacyInfo.xcprivacy                           xcprivacy (config) · 96
├── Services/
│   ├── AppState.swift                              swift · 199
│   ├── DiskCache.swift                             swift · 63
│   ├── MockDataService.swift                       swift · 729
│   ├── NetworkService.swift                        swift · 1453
│   ├── StartupCoordinator.swift                    swift · 97
│   └── StoreKitManager.swift                       swift · 242
├── Theme/
│   └── Theme.swift                                 swift · 537
└── Utils/
    ├── Inspection.swift                            swift · 51
    └── RichText.swift                              swift · 811

frontend/src/                                       [React/Vite web app — reviewable]
├── App.jsx                                         jsx · 40
├── components/
│   ├── AdminGate.jsx                               jsx · 29
│   ├── AdminGate.test.jsx                          jsx (test) · 54
│   ├── AgentChatThread.jsx                         jsx · 176
│   ├── AppBloom.jsx                                jsx · 35
│   ├── AppBloom.test.jsx                           jsx (test) · 130
│   ├── AppNav.jsx                                  jsx · 131
│   ├── AppNav.test.jsx                             jsx (test) · 97
│   ├── BibleCard.jsx                               jsx · 107
│   ├── BibleNavigator.jsx                          jsx · 143
│   ├── BookmarkButton.jsx                          jsx · 192
│   ├── ChatThread.attachments.test.jsx *untracked* jsx (test) · 330
│   ├── ChatThread.jsx                              jsx · 542
│   ├── ChatThread.test.jsx                         jsx (test) · 131
│   ├── ContactsPanel.jsx                           jsx · 346
│   ├── DetectionDetailOverlay.jsx                  jsx · 423
│   ├── DetectionDetailOverlay.test.jsx             jsx (test) · 534
│   ├── DonationButton.jsx                          jsx · 110
│   ├── HighlightPicker.jsx                         jsx · 30
│   ├── MessagingSidebar.jsx                        jsx · 290
│   ├── MobileBlockGate.jsx                         jsx · 41
│   ├── MobileBlockGate.test.jsx                    jsx (test) · 62
│   ├── RichText.jsx                                jsx · 413
│   ├── RichText.test.jsx                           jsx (test) · 110
│   ├── ScriptureNav.jsx                            jsx · 83
│   ├── SessionCreator.jsx                          jsx · 261
│   ├── SessionCreator.test.jsx                     jsx (test) · 175
│   ├── SessionWidget.jsx                           jsx · 356
│   ├── SubscriptionCard.jsx                         jsx · 464
│   ├── VerseSelector.jsx                           jsx · 189
│   └── panels/
│       ├── AgentChatPanel.jsx                      jsx · 100
│       ├── BibleReaderPanel.jsx                    jsx · 161
│       ├── HighlightsPanel.jsx                     jsx · 133
│       ├── MessagingPanel.jsx                      jsx · 96
│       ├── NotesPanel.groupEditPermission.test.jsx jsx (test) · 184
│       ├── NotesPanel.jsx                          jsx · 834
│       ├── NotesPanel.test.jsx                     jsx (test) · 100
│       └── ReaderDockRail.jsx                      jsx · 59
├── config.js                                       js · 2
├── context/
│   ├── AuthContext.jsx                              jsx · 54
│   └── ReaderPanelContexts.jsx                      jsx · 20
├── hooks/
│   ├── useAgentChat.js                             js · 242
│   ├── useBible.js                                 js · 101
│   ├── useBookmarks.js                             js · 40
│   ├── useFocusTrap.js                             js · 56
│   ├── useHighlights.js                            js · 111
│   ├── useHostRect.js                              js · 50
│   ├── useHostRect.test.jsx                        jsx (test) · 160
│   ├── useIsDesktopViewport.js                     js · 26
│   ├── useMessaging.attachments.test.js *untracked* js (test) · 188
│   ├── useMessaging.js                             js · 439
│   ├── useMessaging.test.js                        js (test) · 144
│   ├── useNotes-error-surfacing.test.js            js (test) · 92
│   ├── useNotes.js                                 js · 329
│   ├── useNotes.test.js                            js (test) · 148
│   ├── useParallaxBlobs.js                         js · 94
│   ├── useSessions.js                              js · 438
│   └── useTheme.js                                 js · 14
├── lib/
│   ├── deviceGate.js                               js · 18
│   ├── deviceGate.test.js                          js (test) · 38
│   ├── readerDockLayout.js                         js · 137
│   ├── remediationMarkdown.js                      js · 133
│   └── remediationMarkdown.test.js                 js (test) · 181
├── main.jsx                                        jsx · 37
├── pages/
│   ├── Account.jsx                                 jsx · 1133
│   ├── AdminDetectionDetail.jsx                    jsx · 374
│   ├── AdminDetectionDetail.test.jsx                jsx (test) · 344
│   ├── AdminDetections.jsx                         jsx · 491
│   ├── AdminDetections.test.jsx                     jsx (test) · 443
│   ├── ForgotPassword.jsx                          jsx · 80
│   ├── Home.download-section.test.jsx              jsx (test) · 76
│   ├── Home.jsx                                    jsx · 568
│   ├── Privacy.jsx                                 jsx · 258
│   ├── Reader.dockGlassAudit.test.jsx              jsx (test) · 84
│   ├── Reader.dockGlassFix.test.jsx                jsx (test) · 107
│   ├── Reader.dockNotesGlassToolbar.test.jsx       jsx (test) · 133
│   ├── Reader.dockOutlineFix.test.jsx              jsx (test) · 114
│   ├── Reader.dockPortalBlurFix.test.jsx           jsx (test) · 112
│   ├── Reader.dockRail.test.jsx                    jsx (test) · 370
│   ├── Reader.dockToolbarRadiusFix.test.jsx        jsx (test) · 155
│   ├── Reader.dockVerseMessagesGlass.test.jsx      jsx (test) · 145
│   ├── Reader.dockview.persistence.test.jsx        jsx (test) · 196
│   ├── Reader.dockview.test.jsx                    jsx (test) · 167
│   ├── Reader.jsx                                  jsx · 427
│   ├── ResetPassword.jsx                           jsx · 86
│   ├── SignIn.jsx                                  jsx · 316
│   ├── Terms.jsx                                   jsx · 215
│   └── VerifyMfa.jsx                               jsx · 119
├── styles/
│   ├── global.css                                  css · 1523
│   └── reader-dock.css                             css · 601
├── test/
│   └── setup.js                                    js (test harness) · 16
├── theme.js                                        js · 116
├── utils.js                                        js · 105
└── utils.test.js                                   js (test) · 78

frontend/                                           [legacy static tree — reviewable, ADDED this pass]
│                                                    [nginx-served directly, parallel to the Vite/React app above — NOT dead code]
├── account.html                                    html · 331
├── reader.html                                     html · 319
├── signin.html                                     html · 220
├── css/
│   ├── account.css                                 css · 336
│   ├── base.css                                    css · 151
│   ├── index.css                                   css · 417
│   ├── reader.css                                  css · 2283
│   ├── signin.css                                  css · 195
│   └── tour.css                                    css · 105
└── js/
    ├── bible.js                                     js · 251
    ├── config.js                                    js · 11
    ├── dashboard.js                                 js · 170
    ├── highlights.js                                js · 130
    ├── messaging.js                                 js · 444
    ├── notes.js                                     js · 670
    ├── notes.test.js                                js (test) · 152
    ├── reader.js                                     js · 218
    ├── session.js                                    js · 38
    ├── tour.js                                       js · 340
    ├── utils.js                                      js · 42
    └── utils.test.js                                 js (test) · 55
```

**Note on `frontend/index.html`**: this file is tracked in git and sits alongside the legacy HTML pages, but it is the Vite entry point for `frontend/src/` (it loads `/src/main.jsx`, not any legacy `js/`/`css/` asset). It is not part of the legacy static tree this pass added, and it was not named in the re-entry instruction (which listed `account.html`, `reader.html`, `signin.html` specifically). It remains outside this inventory; flagging its existence here so a downstream step doesn't mistake the omission for an oversight — if the React app's own HTML shell should be in scope, that's a scope call for `compliance-scope-agent`, not silently assumed here.

## Totals

**By language/extension (reviewable files, 161 total):**

| Language/ext | Count | Where |
|---|---|---|
| Swift (`.swift`) | 42 | iOS app |
| iOS config (`.plist`, `.entitlements`, `.storekit`, `.xcprivacy`) | 4 | iOS app |
| JSX (`.jsx`, incl. test files) | 66 | frontend/src |
| JS (`.js`, incl. test files) | 26 | frontend/src |
| CSS (`.css`) | 2 | frontend/src |
| HTML (`.html`) | 3 | frontend legacy tree |
| CSS (`.css`) | 6 | frontend legacy tree (`css/`) |
| JS (`.js`, incl. 2 test files) | 12 | frontend legacy tree (`js/`) |

Of the 66 `.jsx` + 26 `.js` = 92 `frontend/src` files, 32 are test files (`*.test.js(x)` or otherwise clearly test-named). Of the 12 legacy-tree `js/` files, 2 are test files (`notes.test.js`, `utils.test.js`); the 3 legacy `.html` pages and 6 legacy `.css` files carry no colocated tests (this legacy tree has no test harness at all — see Notable structure).

**Total reviewable: 161** (46 iOS + 94 `frontend/src` + 21 legacy `frontend/` static tree).
**Total excluded/skipped: 44** (all on the iOS side — see below; both frontend surfaces had zero exclusions, everything there is text source).

## Excluded paths

All 44 exclusions are inside `FellowScript/FellowScript/`:

- **16× `Contents.json`** (Assets.xcassets tree) — Xcode asset-catalog metadata, machine-generated boilerplate, not authored code.
- **14× `.png`** — binary image assets (app icon, mark, 12 onboarding-tour screenshots).
- **7× `.ttf`** — binary font files (Inter + Playfair Display families).
- **1× `.mov`** — binary video asset (`LoadingScreen/loading-screen.mov`).
- **2× license/doc text** (`Fonts/NOTICE.md`, `Fonts/OFL-Inter.txt`, `Fonts/OFL-PlayfairDisplay.txt`, `Onboarding/TOUR_SCREENSHOT_CAPTURE.md` — 4 files total, license/notice/capture-instructions text, not code subject to architecture review).
- **`Bible/bible.json`** — 4.2MB Bible translation data blob (1,374 lines but ~4.2MB; static reference data, not app logic).
- **`Bible/bible.json.bak-20260712-232858`** — dated backup file, not part of the build.

Also excluded from the sweep by the request's own scoping (not walked at all, not counted above):
- `FellowScriptTests/` and `FellowScriptUITests/` — explicitly excluded by the request.
- `api/` — backend, explicitly out of scope.
- `frontend/index.html` — Vite entry shell for `frontend/src/`, not part of the legacy tree; see note under the diagram above.
- `frontend/node_modules/`, `frontend/dist/`, `frontend/package-lock.json` — dependency/build-output noise, standard exclusion (explicitly reconfirmed as excluded on this re-entry pass too).
- Top-level `ios/` — empty directory (only `.DS_Store`), no files to review.
- Repo-root noise not relevant to either target (`.git/`, `.venv/`, `.pytest_cache/`, `data/`, `data_changes/`, `desktop/`, `docs/`, `site/`, secrets like `.env`/`*.pem`/`AuthKey_*.p8`) — irrelevant to this scope, not enumerated.

**Superseded exclusion (corrected this pass):** the prior version of this file excluded `frontend/css/`, `frontend/js/`, and `frontend/{account,reader,signin}.html` as an assumed-dead legacy surface. That assumption was wrong (confirmed actively maintained, separately deployed by nginx) and those 21 files are now included above — see Scope note.

## Notable structure

- **Three independent frontend surfaces now in scope, no shared code between any of them.** The iOS app (`FellowScript/FellowScript/`) is a SwiftUI target organized by feature folder (Account, Auth, Bible, Chat, Dashboard, Notes, Onboarding) plus a `Services/` layer (networking, disk cache, StoreKit, app state) and a `Theme/` layer. The web app has *two* independently-deployed surfaces sharing the same `frontend/` git root but not sharing code: (1) `frontend/src/` — a Vite/React SPA organized by `components/` (+ nested `panels/`), `pages/`, `hooks/`, `context/`, `lib/`; and (2) the legacy static tree — three standalone HTML pages (`account.html`, `reader.html`, `signin.html`) each paired with their own hand-authored CSS file in `css/` and driven by vanilla JS modules in `js/` (no build step, no bundler, no JSX — this is pre-React-migration architecture, still live in production via direct nginx serving). All three surfaces talk to the same `api/` backend (out of scope here).
- **The legacy tree has no colocated test harness**, unlike both other surfaces. Only 2 of its 12 JS files have tests (`notes.test.js`, `utils.test.js`); the 3 HTML pages and 6 CSS files have zero test coverage. This is a meaningful asymmetry versus `frontend/src/` (32 of 92 files are tests) and even iOS (separate `FellowScriptTests/` target, excluded from this sweep but present) — worth flagging hard to the readability/optimization/logic-error agents, since this is the one surface where a regression wouldn't be caught by any automated check before reaching the nginx-served production pages.
- **`frontend/js/reader.js` and `frontend/css/reader.css` are the legacy counterparts to `frontend/src/pages/Reader.jsx`** — both surfaces independently implement Bible-reader UI. `reader.css` alone is 2,283 lines, larger than any single file in either of the other two surfaces except `NotesListView.swift` and `AccountView.swift` — worth flagging as a likely maintenance-burden hotspot (two parallel reader implementations to keep in sync) for the compliance-scope and logic-error agents.
- **Naming overlaps across surfaces are a landmine for anyone searching by filename alone**: `notes.js` (legacy) vs. `NotesListView.swift`/`NoteEditorView.swift` (iOS) vs. `NotesPanel.jsx` (React); `utils.js` (legacy, 42 lines) vs. `utils.js` (React, `frontend/src/utils.js`, 105 lines) — two *different* files with the identical relative-basename-but-different-path. Downstream agents should always disambiguate by full path, not basename, when cross-referencing this inventory.
- **Test files live alongside source, not in a separate tree, on both web surfaces (where tests exist at all).** Unlike iOS (which keeps `FellowScriptTests/`/`FellowScriptUITests/` as separate targets, excluded from this sweep), both `frontend/src/` and the legacy `frontend/js/` colocate `*.test.js(x)` files as siblings of the file under test.
- **Reader feature has an unusually dense test surface on the React side.** `pages/Reader.jsx` (427 lines of source) has 10 separate colocated test files covering distinct fix/regression scenarios (glass audit, glass fix, notes-glass-toolbar, outline-fix, portal-blur-fix, dock-rail, toolbar-radius-fix, verse-messages-glass, dockview persistence, dockview) — worth flagging to the readability/optimization agents as a signal of either a historically fragile area or a test-organization pattern (many small regression tests vs. one consolidated suite) worth commenting on. This makes the *lack* of any test coverage on the legacy `reader.js`/`reader.css` counterpart (see above) even more notable by contrast.
- **Two untracked, in-progress files on the "attachments" feature**, one per platform: `FellowScript/FellowScript/Chat/MessageAttachments.swift` (682 lines) and `frontend/src/components/ChatThread.attachments.test.jsx` (330 lines) plus `frontend/src/hooks/useMessaging.attachments.test.js` (188 lines) — these are new, not yet committed, and represent parallel in-flight work on both platforms for the same feature (message attachments). Downstream steps should review them as first-class inventory members but flag that they're pre-commit/WIP. The legacy tree had no untracked/in-progress files as of this pass (`git status --porcelain` clean for `frontend/css/`, `frontend/js/`, `frontend/*.html`).
- **iOS asset catalog is large but entirely non-code**: 12 onboarding-tour screenshots plus app icon/mark, each with a `Contents.json` sidecar — this inflates the raw file count (34 files) but contributes zero reviewable lines.
- **`bible.json` is reference data, not configuration** — at 4.2MB it dwarfs every code file in the tree; excluded from LOC-based review but its presence (loaded at runtime by `BibleReaderView.swift`) is worth downstream agents' awareness for e.g. optimization review (bundle size / load strategy), even though the data file itself isn't being reviewed line-by-line.
- **Preference-survey convention file confirmed present** at `~/Downloads/ai_preference_survey_tracker.md` for the scope agent and later steps to consult (per CLAUDE.md) when checking this codebase's frontend work against the user's personal UI/UX Design Philosophy and Configuration Philosophy modules — not read in full here since this step is inventory-only, but its existence is confirmed so `compliance-scope-agent` can build the compliance plan against it.
