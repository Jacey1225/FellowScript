# Take a quick tour prompt

Task 20261105-take-tour-prompt. A dismissible bottom sheet that offers the onboarding walkthrough to a signed-in user whose first-run walkthrough ended without finishing any part.

## Decisions

- **Look and mechanics.** Modeled on the push prompt sheet (`PushPromptSheet`), not the full-screen post-tour covers. The scaffold is reused as-is. Copy: "Take a quick tour" / "Start the tour" / "Not now".
- **Who counts as "not yet taken".** `OnboardingEngine.finishRecap` writes `tourPromptOutcome.v1` at the end of a first-run flow only (never a replay). `skipped` means zero parts completed; finishing one or more parts is `completed`. A missing or unrecognised value never prompts, so people who finished the old 12-step tour and people who finished the new walkthrough are never asked. People who skipped before this build shipped were never recorded and are not prompted.
- **Cadence.** First eligible moment after the skip (never in the same session as the flow), then 7, 14 and 30 days (`TourPromptStore.tourPromptSnoozeDays`), capped at 3 asks.
- **Dismiss.** Tap outside, swipe down and "Not now" all snooze and count as an ask. "Start the tour" resolves the prompt for good.
- **Entry point.** The existing replay path: the survey, then `OnboardingEngine.startReplay(picks:)`. Replay never touches the `PostTourPromptsStore` keys.
- **Ordering (strict priority, never two at once).** Walkthrough, add-a-friend and recap, then post-tour covers, then the push sheet, then this prompt. It is also held back while the push sheet is visible or was shown this session, during calls, the loading screen, terms re-accept, profile completion, a pending invite or the update nudge. The rules live in `TourPromptSuppression`. The push sheet treats this prompt as another presentation, so they cannot race.
- **iPad.** Hosted at the `ContentView` level, so it appears in both phone and workspace layouts. Phone layout shows it only on the Home tab.
- **Flag.** Local UserDefaults flag `tourPromptEnabled`, default on (`TourPromptStore.featureFlagDefault`). Off means never shown; the outcome is still recorded.
- **UI tests.** Suppressed under plain `UI-TESTING`; launch with `UI-TESTING-TOUR-PROMPT` for a skipped-outcome state in isolated defaults.
