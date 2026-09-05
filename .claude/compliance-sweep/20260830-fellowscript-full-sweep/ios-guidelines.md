# iOS Guidelines Compliance Sweep — FellowScript

**Task:** 20260830-fellowscript-full-sweep · **Step:** 7 (`ios-guidelines-agent`)
**Scope reviewed:** `FellowScript/FellowScript/` (app target, 43 source files + Info.plist + entitlements + asset catalog + StoreKit config), `FellowScript/FellowScript.xcodeproj/` (build settings, SPM package pins), cross-referenced against `frontend/src/pages/Privacy.jsx` for stated data-collection claims. Test targets (`FellowScriptTests`, `FellowScriptUITests`) were checked only for what they reveal about production wiring (e.g. `MockDataService` gating), not reviewed as shipping surface.

**Note on method:** The `appstore` skill referenced in this step's instructions is configured with `disable-model-invocation` and explicitly reserves its workflow for direct user invocation — it could not be loaded via the Skill tool, and its content/workflow was not replicated by other means (e.g. reading its file directly) per its own stated restriction. This review instead applies standard, current App Store Review Guidelines and Apple developer documentation knowledge (privacy manifest / required-reason API rules, Guideline 3.1.2 subscription disclosure requirements, Guideline 1.2 UGC requirements, Guideline 4.8 sign-in parity, Guideline 5.1.1(v) account deletion) directly against the code, plist, and entitlements content.

---

## Critical

### 1. No `PrivacyInfo.xcprivacy` privacy manifest exists anywhere in the app target, despite the app using a "required reason" API

- **Location:** Missing entirely — searched the full `FellowScript/` tree (`find -iname "*.xcprivacy"`), zero results.
- **Requirement violated:** Apple's privacy manifest policy requires any app that calls a "required reason" API to declare an approved reason code in a `PrivacyInfo.xcprivacy` file bundled in the target. `UserDefaults` is one of the required-reason API categories (`NSPrivacyAccessedAPICategoryUserDefaults`), and it's called directly in production code:
  - `FellowScript/FellowScript/Bible/BibleReaderView.swift`
  - `FellowScript/FellowScript/Account/HeartbeatScheduler.swift` (`UserDefaults.standard.set/dictionary(forKey: "fs_hb_last_fired")`)
  - `FellowScript/FellowScript/Services/AppState.swift`
- **Why it blocks submission/review:** App Store Connect's automated build-processing step checks binaries for required-reason API usage and cross-references it against the declared manifest. A missing manifest with confirmed required-reason API usage generates a rejection-risk warning at upload today, and Apple has been steadily tightening this from warning to hard block. It also means there is no machine-readable source of truth Apple (or you) can use to verify the App Store Connect "App Privacy" nutrition label matches actual behavior.
- **Suggested fix:** Add `FellowScript/FellowScript/PrivacyInfo.xcprivacy` declaring `NSPrivacyAccessedAPICategoryUserDefaults` with reason code `CA92.1` (access user-defaults keys created by this app/App Group only — matches all three call sites, which only touch app-namespaced keys like `fs_hb_last_fired`, never keys shared with other developers' apps). Populate `NSPrivacyCollectedDataTypes` from the data categories already documented in `frontend/src/pages/Privacy.jsx` §2 (account identifiers, subscription/billing metadata, user content, device/notification data) and set `NSPrivacyTracking` to `false` (no tracking/IDFA usage found anywhere in the target — see Low #7).

---

## High

### 2. Third-party SDK privacy-manifest compliance is unverified for the one SDK that actually ships in the app binary

- **Location:** `FellowScript/FellowScript.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` — `amazon-chime-sdk-ios-spm` pinned at `0.27.3`, linked into the main app target's `packageProductDependencies` (confirmed in `project.pbxproj`, distinct from `ViewInspector`, which is linked only to the test target and therefore doesn't ship). Used from `FellowScript/FellowScript/Chat/ChimeCallView.swift` for audio/video calling.
- **Requirement violated:** Apple's privacy-manifest policy also obligates third-party SDKs (particularly ones performing networking/media/device-fingerprint-adjacent work) to ship their own `PrivacyInfo.xcprivacy` if they use required-reason APIs internally. This can't be confirmed from the repo — the SPM package is fetched at build time, not vendored in-tree.
- **Why it blocks submission/review:** If AmazonChimeSDK 0.27.3's own manifest is missing or incomplete, App Store Connect's aggregated privacy report (built from every linked binary, not just your own target) will surface it, and it becomes a build-processing blocker independent of fixing Critical #1.
- **Suggested fix:** After a build, inspect `~/Library/Developer/Xcode/DerivedData/<project>/SourcePackages/checkouts/amazon-chime-sdk-ios-spm/` (or the `.xcframework`'s `Resources/`) for a bundled `PrivacyInfo.xcprivacy`. If absent, check for a newer AmazonChimeSDK release that includes one before the next submission, since you can't author a manifest on a dependency's behalf.

### 3. Privacy Policy / Terms of Use links are not present on the subscription purchase screen itself

- **Location:** `FellowScript/FellowScript/Account/AccountView.swift` — the purchase flow (`subscriptionSection`, `memberCountPickerRow`, ~lines 699–985, including the "Start" purchase button at line ~976) contains price, trial length, and member-count disclosure, but no Privacy Policy / Terms of Use links. Those links exist only in a separate `privacySafetySection` further down the same scrollable screen (lines 1423–1448, `https://fellowscript.com/#/privacy` and `.../#/terms`).
- **Requirement violated:** Guideline 3.1.2 (Auto-Renewable Subscriptions) requires the purchase surface to clearly and conspicuously provide, alongside title/length/price, functional links to the Privacy Policy and Terms of Use.
- **Why it blocks submission/review:** This is one of the most common real-world 3.1.2 rejection reasons — reviewers frequently reject when the links are reachable only by scrolling to an unrelated settings section rather than being visible from the purchase flow itself.
- **Suggested fix:** Duplicate the two `Link` rows (or a compact single-line footer with both) directly beneath the purchase button in `subscriptionSection`/`memberCountPickerRow`, in addition to (not instead of) the existing `privacySafetySection` entries.

---

## Medium

### 4. `aps-environment` is hardcoded to `development` in the one entitlements file shared by Debug and Release

- **Location:** `FellowScript/FellowScript/FellowScript.entitlements:6` (`<key>aps-environment</key><string>development</string>`). `project.pbxproj` confirms `CODE_SIGN_ENTITLEMENTS = FellowScript/FellowScript.entitlements` is identical for both the Debug and Release build configurations, with `CODE_SIGN_STYLE = Automatic`.
- **Requirement/behavior at risk:** Automatic signing normally lets Xcode rewrite this value to `production` at archive time based on the distribution provisioning profile, but because the checked-in source value is explicitly `development` rather than omitted, a misconfigured or manual export could silently ship a build whose embedded entitlement still reads `development` — which breaks delivery of all push notifications (chat message alerts, `HeartbeatScheduler` scheduled-event notifications) in production with no build-time error.
- **Suggested fix:** Before the next TestFlight/App Store archive, inspect the embedded entitlements in the produced `.ipa` (`codesign -d --entitlements :- YourApp.app`) to confirm it reads `production`, not `development`. Consider not hardcoding a value at all and letting Xcode's automatic-signing entitlement injection be the sole source, to remove the ambiguity.

### 5. App Store Connect "App Privacy" nutrition-label parity has no codebase artifact to check it against

- **Location:** Cross-cutting — `frontend/src/pages/Privacy.jsx` (the in-app-linked privacy policy) is detailed and specific (explicitly disclaims location, contacts, and camera/mic *data collection*, and IDFA), but nothing in the iOS target encodes those same claims in a form Apple's own tooling reads (this is downstream of Critical #1 — the same manifest fix should absorb this).
- **Requirement violated:** App Store Connect's App Privacy questionnaire (declared data types/purposes) is required to match actual app behavior; drift between the policy text and the questionnaire is a submission risk independent of on-device manifest checks.
- **Suggested fix:** Once `PrivacyInfo.xcprivacy` exists (Critical #1), derive its `NSPrivacyCollectedDataTypes` entries directly from `Privacy.jsx` §2's categories so the two can't silently diverge as features are added, and re-verify the App Store Connect questionnaire against the same source at each submission.

---

## Low

### 6. `ITSAppUsesNonExemptEncryption = false` is currently accurate but unguarded against future drift

- **Location:** `FellowScript/FellowScript/Info.plist:5-6`. Full-tree search for `CryptoKit`/`CommonCrypto`/`AES`/`RSA`/`SecKey` found only `Auth/GoogleAuthSession.swift`, which uses `CryptoKit.SHA256` solely for PKCE code-challenge hashing (an export-exempt use) — no custom encryption exists, and this is otherwise accurate.
- **Why flagged:** A faith-community chat app is a plausible candidate for a future "private messages" / end-to-end-encryption feature. If added, this flag must flip to `true` and an export-compliance document (or App Store Connect's export compliance questionnaire) must be filed, or the app risks removal for undeclared encryption.
- **Suggested fix:** Add a short comment next to the key (matching the existing inline-reasoning style already used for the ATS exception a few lines below it) noting it must be revisited the moment any encryption beyond TLS/hashing is introduced.

### 7. No App Tracking Transparency prompt exists — confirmed correct, recorded for future-drift protection

- **Location:** Full-tree search for `ATTrackingManager`, `AppTrackingTransparency`, `IDFA`, `advertisingIdentifier`, and known analytics/ad SDK names (Firebase, Mixpanel, Amplitude, Segment, AppsFlyer, Facebook) across `FellowScript/FellowScript/**/*.swift` returned no matches (the initial `Segment` hits were false positives on unrelated `SegmentedDurationControl`/UI-tab "segment" naming, verified by inspection).
- **Why flagged (not a violation):** Recorded as a confirmed-clean baseline so that if an analytics or ad-mediation SDK is added later, its introduction is the trigger for an ATT review rather than something that ships unnoticed alongside a feature PR.
- **Suggested fix:** None needed today. No action beyond noting this baseline for future add/dependency reviews.

---

## Confirmed compliant (recorded, not findings)

For context on what's already handled correctly, so future changes don't regress these:

- **Guideline 1.2 (UGC apps):** report-a-user (`Chat/ReportUserSheet.swift`, explicitly commented "Guideline 1.2") and block/unblock (`Account/BlockedUsersView.swift`, same comment) are implemented and wired to real backend calls.
- **Guideline 4.8 (sign-in parity):** Sign in with Apple (`Auth/AuthView.swift`, `SignInWithAppleButton`, explicitly commented "required by Guideline 4.8") is offered alongside Sign in with Google (`Auth/GoogleAuthSession.swift`, native PKCE flow, no bundled GoogleSignIn SDK) and email/password.
- **Guideline 5.1.1(v) (account deletion):** In-app "Delete Account" flow exists in `Account/AccountView.swift`.
- **Guideline 3.1.2 (subscription content):** Price, trial length ("Free for 1 month"), and member-count/benefits disclosure are present on the purchase screen; a "Restore Purchases" button exists and is wired to `StoreKitManager.restore`.
- **Camera/microphone usage strings** (`Info.plist`) are present, specific, and accurate to actual usage (`ChimeCallView.swift`'s `AVCaptureDevice.requestAccess(for: .video)` and the Chime SDK's own mic prompt on `audioVideo.start()`).
- **App icon** asset catalog uses the modern single 1024×1024 universal format with the referenced PNG actually present on disk.
- No HIG-overriding system-affordance code found (no home-indicator hiding, no interactive-pop-gesture disabling, no forced interface-orientation lock, no back-button hiding).
- No `BGTaskScheduler`/background-processing usage beyond the declared `remote-notification` background mode, and push registration is correctly gated behind an explicit authorization request (`Services/AppState.swift`).
- `MockDataService` is strictly gated behind a `UI-TESTING` launch argument set only by the XCUITest scheme — confirmed it cannot be reached in a TestFlight/App Store build.

---

## Summary

Reviewed the FellowScript iOS app target's Info.plist, entitlements, SPM dependency graph, and the Swift source for privacy-manifest coverage, permission-string accuracy, third-party SDK shipping status, tracking/ATT exposure, export-compliance accuracy, subscription-flow disclosure (Guideline 3.1.2), and inferable HIG/system-affordance overrides. One Critical finding (no `PrivacyInfo.xcprivacy` at all, despite confirmed `UserDefaults` "required reason API" usage in three production files) and two High findings (unverified third-party AmazonChimeSDK privacy-manifest coverage; Privacy Policy/Terms links absent from the subscription purchase screen itself, only present elsewhere in the same scrollable Account view) are the headline submission risks. Two Medium findings (hardcoded `aps-environment: development` in the shared entitlements file; no codebase artifact keeping the App Store Connect privacy nutrition label in sync with the in-app policy) and two Low forward-looking findings (encryption-flag drift guard; ATT baseline) round out the report. The app was also found to already correctly implement several guideline requirements (UGC reporting/blocking, Sign in with Apple parity, in-app account deletion, subscription restore) that are recorded so future changes don't regress them.
