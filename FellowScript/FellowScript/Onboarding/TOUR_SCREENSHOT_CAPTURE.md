# Onboarding tour screenshot capture checklist

`OBTour`'s 12 `TourStep.all` entries (`OnboardingView.swift`) each render a real
Simulator screenshot from `Assets.xcassets/OnboardingTour/` inside
`OBMockPhone`'s miniature-phone chrome, not a hand-drawn recreation. This is
the repeatable process for refreshing those screenshots the next time the
real screens' UI changes enough to make them stale (task
`20260902-onboarding-tour-real-screenshots`; the tour had already gone stale
once before via hand-drawn mocks — see `20260818-ios-tour-visual-fidelity` —
this real-screenshot approach exists specifically to stop that from
recurring).

## 1. Capture provenance (last captured)

- **Simulator:** `FellowScript-Screenshot`, iPhone 17, iOS 26.5, fresh
  install, `main` at the time of capture.
- **Account:** `MockDataService`'s built-in `UI-TESTING` launch-argument mock
  account (`jacob` / `password`) — already fully populated (2 friends, 1
  group, 6 notes, 1 agent, 1 scheduled session, 5 highlights) with no
  real-user data. One addition was needed and made permanently to
  `MockDataService.swift`: `mockHeartbeat`, a demo Events/heartbeat fixture,
  since the mock account previously had zero events and the EVENTS tour step
  requires showing a populated state, not an empty one.

## 2. Re-running the capture

The capture mechanism is `FellowScriptUITests/OnboardingTourScreenshotCaptureUITests.swift`
— one independent XCTest method per screenshot (or tight group of two on the
same screen), each with its own fresh `signInAndReachDashboard()`. Keep them
independent: an earlier single chained test lost 6 of 12 screenshots to one
flaky interaction cascading into every capture after it — see that file's
header comment.

```sh
xcodebuild test-without-building \
  -project FellowScript.xcodeproj -scheme FellowScript \
  -destination "id=<FellowScript-Screenshot simulator UDID>" \
  -derivedDataPath <path> \
  -only-testing:FellowScriptUITests/OnboardingTourScreenshotCaptureUITests
```

Each test writes its raw, uncropped, full-device PNG to
`/tmp/onboarding-tour-raw/<asset-name>.png`. Re-run per-method
(`-only-testing:.../test_captureX`) if only one screen changed — no need to
redo all 12 every time.

Known live caveats in a sandboxed/offline test run, not bugs in the app:
- `tour-group-session`'s capture shows a "Reconnecting…" pill (the chat
  websocket has no real server to reach from this environment) and the
  group-thread header truncates a long title ("Wedn…") — both are real,
  accurate renders of that state, not capture artifacts to fix.
- `tour-account`'s Subscription section can intermittently render its
  loading spinner instead of settled content depending on timing — if the
  raw capture shows the spinner, just re-run that one test.

## 3. Crop spec

All 12 assets share one target aspect ratio, **not** just "strip the status
bar" — `OBMockPhone`'s actual on-screen content band (measured live) is
**1206 : 1035** (≈1.165:1), because `OBMockPhone` is a small, roughly-square
330pt-tall miniature frame, while a real device screenshot is a tall
portrait rectangle. Cropping only the status bar/tab bar (as this task first
tried) leaves an image roughly twice too tall — at runtime, `.aspectRatio(.fill)`
then crops away *another* ~50% of it to force-fit the frame, and which ~50%
survives isn't something you get to choose. Pre-cropping to the real target
aspect ratio up front means the in-app `.fill` only does the "minor rounding"
job it was always meant to do, and you keep control over which part of each
screen is actually shown.

Crop every raw `/tmp/onboarding-tour-raw/<name>.png` (1206×2622px, iPhone 17
@3x) to **1206×1035px**, choosing the vertical window per the table below
(all values are pixel `top` offsets into the raw 2622px-tall image; crop box
is `(0, top, 1206, top+1035)`):

| Asset | `top` | Why |
|---|---|---|
| `tour-dashboard` | 186 | Status-bar bottom (62pt × 3 scale) — every "custom in-body header" screen (Home/Notes/Chat) shares this. |
| `tour-bible-nav` | 186 | Same — native inline nav bar sits right below the status bar too. |
| `tour-highlights` | 186 | Same. |
| `tour-group-notes` | 186 | Same. |
| `tour-friend-chat` | 186 | Same. |
| `tour-create-note` | 186 | NoteEditorView's default `.sheet` covers the full screen including behind the status bar — same top inset works. |
| `tour-add-friend` | 1245 | `.presentationDetents([.medium])` sheet's own top edge/grabber (measured live), not the status bar. |
| `tour-create-group` | 1245 | Same (medium/large sheet). |
| `tour-group-session` | 186 | ChatThreadView's custom header, same convention as Home/Notes/Chat. |
| `tour-ai-agent` | 186 | Same. |
| `tour-account` | 480 | `AccountView` uses a *native* `NavigationStack` large title, which sits noticeably lower than the custom headers above (confirmed live, per design-notes.md's flagged verify-point) — this offset was tuned so the OVERVIEW stat card is fully visible in-frame, not just the greeting. If Account's layout changes, re-measure rather than assuming 480 still centers the right content. |
| `tour-heartbeat` | 1225 | Scrolled state — not top-anchored at all. This is the y-offset (in the *raw*, unscrolled-then-scrolled capture) that centers the seeded Events card. If the Account screen's section order or card heights change, re-find the Events card's own top/bottom (e.g. crop a ruled strip and eyeball it — see the git history of this task for the exact technique) and recenter. |

After cropping, drop each into
`Assets.xcassets/OnboardingTour/<name>.imageset/<name>.png`, keeping the
single "universal" idiom slot (no @1x/@2x/@3x split needed — Simulator
screenshots are already captured at native Retina density).

## 4. Verify

1. Build the app and run `FellowScriptUITests/OnboardingTourUITests` — it
   walks all 12 steps in section order and confirms the tour finishes
   cleanly into the CTA phase.
2. Spot-check a couple of the new crops by eye (`Assets.xcassets/OnboardingTour/*.imageset/*.png`)
   to confirm the content that matches each `TourStep`'s heading/body/hint
   copy is actually visible in the cropped frame, not cropped away.
