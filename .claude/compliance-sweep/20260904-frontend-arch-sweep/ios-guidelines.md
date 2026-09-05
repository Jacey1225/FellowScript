# iOS Guidelines Compliance Sweep — 20260904-frontend-arch-sweep

Scope: `FellowScript/FellowScript/` (46 reviewable files per `file-inventory.json`), Xcode project at
`FellowScript/FellowScript.xcodeproj`. Reviewed: `Info.plist`, `PrivacyInfo.xcprivacy`,
`FellowScript.entitlements`, `FellowScript.storekit`, `project.pbxproj` / `Package.resolved`, and the
Swift source for every permission-adjacent, payment-adjacent, sign-in, and UGC-moderation surface
(`Services/StoreKitManager.swift`, `Services/NetworkService.swift`, `Services/AppState.swift`,
`Services/DiskCache.swift`, `Auth/*`, `Chat/ChimeCallView.swift`, `Chat/MessageAttachments.swift`,
`Chat/ReportUserSheet.swift`, `Account/AccountView.swift`, `Account/BlockedUsersView.swift`,
`Dashboard/FloatingTabBar.swift`, `Theme/Theme.swift`, and every file using `.animation`/`withAnimation`).

**Methodology note:** the `appstore` skill (this task's nominal source for the section 2/3 checklist)
is configured `disable-model-invocation` and could not be loaded by this agent — it is reserved for
explicit user invocation and the tool declined to run it or have its workflow replicated by other
means. This review instead applied Apple's public App Store Review Guidelines and Privacy Manifest
requirements directly (App Tracking Transparency, required-reason API declarations, purpose-string
accuracy, Guideline 1.2/4.8/5.1.1/3.1.x, export compliance) against the actual code/plist/manifest
contents. The orchestrator/user should be aware the specific `appstore` skill checklist itself was not
consulted verbatim.

**Overall finding:** this target shows unusually strong, deliberate prior compliance work — Guideline
1.2 (zero-tolerance re-consent flow in `Auth/TermsReacceptView.swift`, in-app blocking and reporting),
Guideline 4.8 (Sign in with Apple offered alongside Google, equal visual prominence, explicitly
commented), Guideline 5.1.1(v) (in-app account deletion in `Account/AccountView.swift`), Guideline
3.1.2/3.1.3(b) (StoreKit-native introductory free trial, no external checkout links, Stripe/web plans
handled as "unlock elsewhere" without an in-app purchase path), and export compliance
(`ITSAppUsesNonExemptEncryption = false`, with a correct, well-reasoned comment about the one CryptoKit
hashing use) are all already correctly implemented and commented in-line with the guideline numbers
they satisfy. No permission (`NS...UsageDescription`) is requested without a matching, accurate purpose
string, and no ATT/IDFA usage exists anywhere in the target. The findings below are the residual gaps,
none of which are contradicted by anything above.

## Medium

### 1. Reduce Motion / `prefers-reduced-motion` support is inconsistent across the animation-heavy UI
- **Where:** App-wide. Only `Bible/BibleReaderView.swift`, `Chat/MessageAttachments.swift`,
  `LoadingScreen/LoadingScreenView.swift`, and `Dashboard/DashboardComponents.swift` read
  `@Environment(\.accessibilityReduceMotion)`. Files that call `.animation(...)`/`withAnimation` but
  never check it: `Onboarding/OnboardingView.swift` (11 call sites), `Auth/AuthView.swift` (2),
  `Chat/ChatThreadView.swift` (2), `Notes/NotesListView.swift` (4), `ContentView.swift` (4),
  `Account/AccountView.swift`, `Chat/AgentChatView.swift` (5), `Notes/NoteEditorView.swift`,
  `Chat/ChatRootView.swift`, `Chat/ChipToggle.swift`, `Chat/SegmentedDurationControl.swift`,
  `Dashboard/FloatingTabBar.swift`.
- **Requirement:** Apple's accessibility HIG expectation that motion effects respect the system Reduce
  Motion setting — called out as this project's own stated floor in this sweep's preference profile
  (UI/UX Q14.3), given the "animation-heavy vaunted style."
- **Why it matters:** not an automatic App Review rejection trigger by itself, but is precisely the
  class of accessibility gap App Review has increasingly scrutinized for visually-rich apps, and is a
  real user-facing failure for vestibular-sensitive users independent of review risk.
- **Fix:** thread `@Environment(\.accessibilityReduceMotion)` through the listed files and gate
  animations the way `MessageAttachments.swift`'s `gifContent` already models (skip/replace the motion
  effect, don't just shorten it).

### 2. AmazonChimeSDK privacy-manifest patch build phase fails silently open
- **Where:** `FellowScript.xcodeproj/project.pbxproj`, the "Patch AmazonChimeSDK Privacy Manifest" shell
  script build phase (runs last, after Sources/Frameworks/Resources, on the main `FellowScript` target).
- **What it does:** correctly works around a real upstream bug — AmazonChimeSDK 0.27.3/0.27.4 (pinned
  in `Package.resolved`) ship a `PrivacyInfo.xcprivacy` whose `NSPrivacyCollectedDataTypePurposes` entry
  is free text instead of one of Apple's fixed enum constants, which App Store Connect rejects at
  submission with ITMS-91056 ("Invalid privacy manifest"). The script patches the embedded copy in
  place before signing.
- **The gap:** if `$CODESIGNING_FOLDER_PATH/Frameworks/AmazonChimeSDK.framework/PrivacyInfo.xcprivacy`
  isn't found at that exact path (e.g. after a future SPM version bump changes the framework's internal
  layout), the script only echoes `"warning: ... skipping the patch"` and exits 0 — it does not fail the
  build.
- **Why it matters for submission:** a future dependency bump could silently reintroduce the invalid
  manifest with zero build-time signal, surfacing only as an ITMS-91056 rejection at the next App Store
  Connect upload — exactly the failure mode this script exists to prevent.
- **Fix:** make the "not found" branch `exit 1` (fail the build) instead of warn-and-continue, so a path
  change is caught locally instead of at submission.

### 3. `aps-environment` hardcoded to `development` in the one shared entitlements file for both configs
- **Where:** `FellowScript/FellowScript/FellowScript.entitlements` (used as
  `CODE_SIGN_ENTITLEMENTS` for both the Debug and Release build configurations of the main target,
  per `project.pbxproj`).
- **Detail:** `CODE_SIGN_STYLE = Automatic` for both configs, which normally causes Xcode to substitute
  the correct `aps-environment` value (`production`) at archive/export time based on the actual
  distribution provisioning profile — so this is likely fine in practice, and is not being reported as a
  confirmed defect.
- **Why it's flagged anyway:** the app depends on push notifications for a real feature (session
  created/reminder pushes, handled in `Services/AppState.swift`'s `registerDeviceToken`/`openSession`
  and `FellowScriptApp.swift`'s `AppDelegate`), so a silently-wrong APNs environment in a shipped build
  would be a Guideline 2.1 (App Completeness — advertised functionality must work) issue that's easy to
  miss because it fails silently (no crash, no visible error — reminders simply never arrive).
- **Fix:** one-time confirmation at the next TestFlight/App Store archive: inspect the exported IPA's
  embedded entitlements (or the distribution provisioning profile) and confirm `aps-environment` reads
  `production`, not `development`.

## Low

### 4. Hand-built "Continue with Apple" button bypasses the native control's automatic HIG conformance
- **Where:** `Auth/AuthView.swift`, lines ~215–237.
- **Detail:** substitutes a plain `Button` driving `ASAuthorizationController` directly
  (`AppleAuthSession.swift`) in place of SwiftUI's native `SignInWithAppleButton`
  (`ASAuthorizationAppleIDButton`-backed), due to a well-documented, well-reproduced tap-handling bug in
  the native control (see the inline comment citing task `20260903-apple-signin-no-response`). The
  replacement is reasonable and still uses Apple's own auth APIs underneath.
- **Why it matters:** the native control automatically tracks Apple's Sign in with Apple button HIG
  spec (logo/text lockup, minimum sizing, approved color combinations); a hand-rolled lookalike does
  not get spec updates for free.
- **Fix:** no code change required now (current styling — white background, black text, Apple logo +
  "Continue with Apple", 50pt height — matches a currently-approved variant) — just periodically diff
  against Apple's current Sign in with Apple button HIG page when this button is next touched.

### 5. Guideline 1.2 (UGC) verification is necessarily partial from an iOS-only scope
- **Where:** `Chat/ReportUserSheet.swift` (reporting), `Account/BlockedUsersView.swift` (blocking),
  `Auth/TermsReacceptView.swift` (zero-tolerance re-consent gate) — all present and well-integrated
  client-side.
- **Gap:** Guideline 1.2 also requires that reports actually get acted on (a 24-hour response
  commitment) and a published contact mechanism — both of which live in `api/`, explicitly out of
  scope for this frontend-only sweep. Flagging only so the final compliance report doesn't imply
  Guideline 1.2 was verified end-to-end; the client-side half is confirmed complete.

### 6. Third-party SDK (AmazonChimeSDK) privacy-manifest currency isn't tracked on an ongoing basis
- **Where:** `Package.resolved` pins `amazon-chime-sdk-ios-spm` at 0.27.3; linked to the main app
  target's Frameworks build phase (confirmed — not test-only, unlike `ViewInspector` which is correctly
  scoped to `FellowScriptTests` only).
- **Detail:** the SDK performs microphone/camera capture and network I/O and is already known to need
  the manual patch described in Medium #2. Apple's list of third-party SDKs required to ship a *signed*
  privacy manifest is periodically updated; Chime SDK is not currently confirmed to be on that list, but
  given its access pattern this is worth a recheck whenever the pinned version changes.

## Findings summary

| # | Severity | Area |
|---|---|---|
| 1 | Medium | Accessibility — Reduce Motion coverage |
| 2 | Medium | Build config — third-party SDK privacy-manifest patch resilience |
| 3 | Medium | Entitlements — `aps-environment` production verification |
| 4 | Low | HIG — custom Sign in with Apple button drift risk |
| 5 | Low | Guideline 1.2 — scope boundary note (backend half unverifiable here) |
| 6 | Low | Third-party SDK — ongoing privacy-manifest currency |

No Critical or High findings.
