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

## UI parity fix (2026-09-06)

Investigation (task `20260905-desktop-reader-ui-parity`) found the desktop
window was never actually rendering the Reader page:

- **Root cause**: `frontend/src/App.jsx` uses React Router's `HashRouter`,
  so the live Reader route is only reachable at
  `https://fellowscript.com/#/reader`. `tauri.conf.json`'s `app.windows[0].url`
  and `build.devUrl` were set to the bare `https://fellowscript.com/reader`
  (no `#/`). The server has no route-specific handling — `curl` confirmed
  `/reader` and `/` return byte-identical `index.html` — so a fresh load with
  an empty `location.hash` resolves `HashRouter` to `/` and renders `<Home />`,
  not `<Reader />`. This single misconfiguration explains the "missing UI
  components" report: the entire Reader dockview workspace (notes, messaging,
  highlights, AI chat) was simply never mounting.
  - **Fix**: both `app.windows[0].url` and `build.devUrl` now point at
    `https://fellowscript.com/#/reader`.

- **External links (`target="_blank"`) were unwired.** `RichText.jsx`,
  `ChatThread.jsx`, `SignIn.jsx`/`VerifyMfa.jsx` all render `target="_blank"`
  anchors, but nothing in the desktop app handed `window.open()`/new-window
  requests off to the system browser — Tauri's default behavior for these is
  to silently deny them inside a bare webview.
  - **Fix**: added `tauri-plugin-opener` (`2.5.5`, resolved via `cargo add`)
    to `Cargo.toml`. The "main" window is now declared with `"create": false`
    in `tauri.conf.json` and instead built by hand in `src-tauri/src/lib.rs`'s
    `setup()` via `WebviewWindowBuilder::from_config`, with an `on_new_window`
    handler that calls `app_handle.opener().open_url(...)` and returns
    `NewWindowResponse::Deny` (so no defunct native child window is ever
    created — the request is fully redirected to the system default browser).
    `capabilities/default.json` grants only `opener:allow-open-url` scoped to
    `{"url": "https://*"}` — not the plugin's broader `opener:default`
    permission set (which also covers `mailto:`/`tel:`/reveal-in-Finder),
    consistent with this project's deny-by-default posture.

- **Native macOS Edit menu — investigated, found already working.** The
  intake spec's finding assumed Tauri's default menu lacked a proper Edit
  submenu (Undo/Redo/Cut/Copy/Paste/Select All), which would break
  Cmd+Z/Cmd+A in the note editor and message composer. Reading the actual
  pinned `tauri` crate source (resolves to `2.11.5`) showed this is outdated:
  as of this version, `Builder::build()` on macOS automatically installs
  `Menu::default()` — which already includes a full Edit submenu with native
  OS accelerators — whenever no menu has been set explicitly
  (`enable_macos_default_menu` defaults to `true`). So Cmd+Z/Cmd+A already
  worked with zero config. `lib.rs` now calls `.menu(Menu::default)`
  explicitly anyway, so this isn't left as implicit framework behavior that a
  future Tauri upgrade could silently change — it's documented, in source,
  and testable.

- **File export (`remediationMarkdown.js`) confirmed out of scope.** Verified
  by grep: it's only imported from `AdminDetectionDetail.jsx` and
  `DetectionDetailOverlay.jsx`, both under `/admin`, `/admin/detections/:id`
  — routes `App.jsx` itself comments as "Hidden admin-only surface: not
  linked from AppNav or any other page." Not reachable from the Reader page
  this desktop wrapper scopes to. No `dialog`/`fs` plugin work needed.

- **Notifications confirmed no-op.** Grepped all of `frontend/src` for
  `new Notification`, `Notification.requestPermission`, `window.Notification`
  — zero matches. The live reader doesn't use the browser Notification API
  anywhere, so `tauri-plugin-notification` is not needed.

- **Security gate fix: `on_new_window` enforced no scheme check of its own.**
  The `capabilities/default.json` scope (`opener:allow-open-url` restricted to
  `{"url": "https://*"}`) only applies to the IPC-invoked `open_url` command —
  `OpenerExt::open_url`, the direct Rust API called from `lib.rs`'s
  `on_new_window` handler, bypasses that scope check entirely (confirmed by
  reading the pinned `tauri-plugin-opener` 2.5.5 source: `commands::open_url`
  does the `Scope::is_url_allowed` check, `Opener::open_url` does not). Since
  `url` there comes from webview new-window/`window.open()` requests, which
  can be influenced by remote/user-generated content (note bodies, chat
  messages), an unfiltered forward to the OS's default-app opener could hand
  off an arbitrary scheme (e.g. `file://`, or another installed app's
  registered deep-link handler) from a crafted link. Fixed by adding an
  explicit `url.scheme() == "https"` check in the handler itself before
  calling `open_url`, so the capability's declared intent is actually
  enforced in code, not just on paper.

Files touched: `src-tauri/tauri.conf.json`, `src-tauri/Cargo.toml` (+
`Cargo.lock`), `src-tauri/capabilities/default.json`,
`src-tauri/src/lib.rs`. Verified with `cargo check` and `cargo clippy`
(both clean) — a real visual/screenshot launch check of the running app
(dockview workspace rendering, link handoff, keyboard shortcuts) is the
`testing` gate's job for this task, since this environment has no display.

## Desktop scope lockdown — Tauri-side defense-in-depth (2026-09-06)

Task `20260906-desktop-scope-lockdown`: the desktop app is scoped to just the
reader and account pages (plus the auth-flow routes needed to sign in from a
fresh install — sign-in, forgot-password, reset-password, verify-2fa). The
primary enforcement is a frontend route guard
(`frontend/src/components/DesktopRouteGuard.jsx`, driven by the single
allowlist in `frontend/src/lib/desktopScope.js`), since HashRouter
`Link`/`navigate()` calls are same-document history pushes that never produce
a real webview navigation event — `on_new_window` (used for the external-link
handoff above) can't see them at all.

- **Added**: `src-tauri/src/lib.rs` now also registers `on_navigation` on the
  same `WebviewWindowBuilder` chain as `on_new_window`, with its own
  hand-kept mirror of the same allowlist (`DESKTOP_ALLOWED_ROUTES`). Unlike
  `on_new_window`, this fires for real main-frame navigations in the
  existing window — a full page load/reload or a `window.location`
  assignment — which is exactly the case the frontend guard can't see.
  Checks the request's origin (`https://fellowscript.com`) and, since
  HashRouter keeps the route in the URL fragment rather than the path, the
  fragment against the allowlist; anything else is denied and logged.
  Coexists with `on_new_window` without altering it — they're independent
  builder callbacks covering different navigation types (new-window/
  `window.open()` vs. same-window).
- Not touched: `on_new_window`'s external-link-to-system-browser handoff,
  the native menu, `capabilities/default.json` (no new IPC-scoped permission
  needed — `on_navigation` is a Rust-side builder hook, not an invoked
  command).
- Verified with `cargo check` and `cargo clippy` (both clean). A real
  visual/interactive check that the allowlist holds in the running app is
  the `testing` gate's job for this task, per this environment having no
  display.

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
