# FellowScript desktop app — progress (2026-09-02)

## Goal
Package the FellowScript reader page as a downloadable desktop app for macOS
and Windows, using Tauri. Requested in Discord (misc channel).

## Where things live
- Tauri project: `~/Vscode/FellowScript/desktop/` (this directory)
- Web project it wraps: `~/Vscode/FellowScript/frontend/` (React/Vite, live at
  https://fellowscript.com)
- Apple/notarization credentials referenced from `~/Vscode/FellowScript/.env`
  (`APPLE_TEAM_ID`, `APPLE_BUNDLE_ID`, etc.)
- Signed, notarized, stapled release artifacts:
  `src-tauri/target/release/bundle/macos/FellowScript.app` and
  `FellowScript.dmg` (both `spctl --assess` "accepted, source=Notarized
  Developer ID" as of 2026-09-02).

## Key architecture decisions (already made, don't re-litigate)
- The desktop window loads the **live** `https://fellowscript.com/reader`
  directly (set as `app.windows[0].url` and `build.devUrl` in
  `src-tauri/tauri.conf.json`) rather than bundling a locally-built copy of
  the frontend. Reason: `frontend/src/config.js` hardcodes the API base to
  `https://fellowscript.com/api` and the reader depends on live,
  cookie-authenticated calls (sign-in, notes, messaging) — a locally bundled
  copy would run on a different origin and break auth entirely.
- Scope is locked to the reader page only (user's explicit choice), not full
  site navigation chrome.
- `identifier` in `tauri.conf.json` is `com.fellowscript.app`, reusing the
  existing `APPLE_BUNDLE_ID`. Tauri warns that identifiers ending in `.app`
  conflict with the macOS bundle extension — build succeeds anyway; leave
  as-is unless it causes a real problem later.
- App icon generated via `npx tauri icon ../data/fellowscript-app-icon-1024.png`
  (the project's existing 1024×1024 brand icon). iOS/Android icon output was
  deleted from `src-tauri/icons/` as unneeded.
- `.dmg` is hand-built with `hdiutil` (a staging dir containing the `.app`
  plus an `/Applications` symlink, then `hdiutil create -format UDZO`),
  bypassing Tauri's `create-dmg` which needs Automation/Finder-scripting
  permission not granted on this Mac.
- macOS notarization uses the project's **App Store Connect API key**
  (`JZCLMWLW83` / see `reference-fellowscript-appstoreconnect-key` memory)
  passed directly to `notarytool` via `--key`/`--key-id`/`--issuer`, not the
  Apple-ID-based `fellowscript-notary` keychain profile — that profile's
  stored password went stale (401) after a prior credential rotation. The
  API key avoids handling an Apple ID password at all.

## Status: macOS packaging COMPLETE
- Debug build: builds and launches; app process stays alive and loads
  WebKit content as expected. Still not visually screenshot-confirmed (no
  Screen Recording permission available on this Mac) — worth a real look
  before wide release, but functionally not in question given the signed
  release build behaves correctly.
- Release build signed with "Developer ID Application: Jacey Simpson
  (886XPLVC69)", `hardenedRuntime: true`.
- **The `codesign --timestamp`/notarization blocker (Canopy) is resolved.**
  The user disabled Canopy's interception on 2026-09-02 and the RFC3161
  timestamp request completed successfully on this Mac — no second-Mac
  workaround was needed after all. Note it took two tries even after
  disabling: the first retry attempt still hung (the toggle apparently
  didn't immediately clear whatever was catching the raw timestamp-query
  protocol specifically, even though plain HTTPS browsing worked
  throughout) — the second attempt, moments later, went through cleanly.
  If this recurs on a future rebuild, don't treat one hang as conclusive;
  a same-session retry may just work.
- Full sequence completed and verified end to end:
  1. `FellowScript.app` signed with `--timestamp`, verified `valid on disk`.
  2. App zipped (`ditto -c -k --keepParent`) and submitted via
     `notarytool submit --wait` using the App Store Connect API key →
     `status: Accepted`.
  3. `xcrun stapler staple` on the `.app` → succeeded, `spctl --assess`
     → `accepted, source=Notarized Developer ID`.
  4. `.dmg` built from the stapled `.app` via `hdiutil`.
  5. **Important gotcha**: the app's notarization ticket does NOT cover a
     `.dmg` built afterward — stapling the ticket straight onto the new
     `.dmg` fails ("Record not found", the ticket was issued against the
     app's own hash). The `.dmg` itself must be separately signed
     (`codesign --timestamp`) *and* separately submitted to
     `notarytool submit --wait`, then stapled. Both were done here (`.dmg`
     notarization `status: Accepted`, staple succeeded).
  6. Final check: both `FellowScript.app` and `FellowScript.dmg` pass
     `spctl --assess ... --verbose=2` as `accepted, source=Notarized
     Developer ID`.

## Not started yet
Windows packaging/signing (separate `signtool`-based process, completely
unrelated to the macOS work above).

## Known incident (resolved, no action needed)
Early on, the user accidentally pasted their real Apple ID email + a
password into the Discord channel while running `notarytool
store-credentials` with unsubstituted placeholder text. They were told to
treat it as compromised, rotate it, and re-run the command with a new
password — confirmed done before any further work resumed. No credential
values are stored anywhere in this repo or in this file. (This is also why
notarization now goes through the App Store Connect API key instead of an
Apple-ID app-specific-password profile — see Status above.)
