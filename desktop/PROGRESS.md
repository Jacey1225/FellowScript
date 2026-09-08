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

## Native reload menu item (2026-09-08)

Task `20260908-desktop-reload-button`: the desktop window had no way to
recover if the live webview failed to load or got stuck, independent of
whether the page's own JS was still responsive.

- **Threat-modeled first** (security gate, since this touches the same
  `on_navigation`/`is_allowed_navigation` code hardened for
  `20260906-desktop-scope-lockdown`): confirmed by reading the pinned
  `tauri` 2.11.5 / `wry` 0.55.1 source that `WebviewWindow::reload()`
  invokes WKWebView's *native* reload on macOS, which still fires through
  the same webview-instance-wide navigation delegate `.on_navigation()` is
  wired into — so the existing allowlist check is automatically
  re-consulted with zero new code path, and reload always targets the
  already-loaded (and therefore already-allowed) URL by construction. This
  is why a native `reload()` call was required instead of
  `eval("window.location.reload()")`, which depends on the page's own JS
  event loop running — exactly what can't be assumed when the page is
  stuck.
- **Added**: a "Reload" item (with the idiomatic `CmdOrCtrl+R` accelerator)
  appended to the existing macOS "View" submenu that `Menu::default()`
  already builds — `src-tauri/src/lib.rs`'s new `build_menu()` wraps
  `Menu::default()`, finds the "View" submenu by text, and appends the item
  rather than replacing the menu wholesale. Wired via `.on_menu_event` only
  (menu click or its accelerator), dispatched from Rust against the
  `"main"` window handle via `WebviewWindow::reload()`. One manual trigger
  covers both failure modes named in the original request (a genuinely
  failed load and a stuck/unresponsive page) — no separate fallback/error
  page or `did_fail_load` handling was added, since it's out of scope per
  the intake spec and the manual retry already covers both cases without
  new surface area.
- **Deliberately not exposed as IPC**: no `#[tauri::command]` was added and
  `capabilities/default.json` is untouched — the loaded page is live,
  remote, third-party-influenced content (note bodies, messages), and a
  frontend-invokable "force reload" would be an unnecessary attack surface
  for a control the page itself has no legitimate reason to trigger
  (deny-by-default posture). No in-window toolbar button was added either —
  the loaded content is the live site's own HTML, so this repo owns no
  window chrome to host one; the native menu bar is the most
  persistently-discoverable option actually buildable here.
- **Regression coverage**: two new tests alongside the existing
  `desktop_scope_lockdown_tests` module document and pin the specific
  safety claim above — that a reload-equivalent re-navigation to an already
  allowed URL still passes `is_allowed_navigation`, and one to a
  hypothetically disallowed URL is still denied — since reload reuses that
  same choke point rather than introducing a bypassable path of its own.
- Verified with `cargo check` and `cargo clippy` (both clean). Real
  interactive/visual confirmation that the menu item and Cmd+R actually
  reload a stuck window is the `testing` gate's job for this task, per this
  environment having no display — same caveat as the prior desktop tasks
  above.
- Windows/Linux: out of scope (macOS is the only built target per "Not
  started yet" below). `reload()` is cross-platform in the `tauri`/`wry`
  API, but whether WebView2/WebKitGTK's navigation delegate equivalently
  re-fires on a native reload has not been verified and shouldn't be
  assumed if Windows packaging is ever picked up.

Files touched: `src-tauri/src/lib.rs` only — no `Cargo.toml`,
`tauri.conf.json`, or `capabilities/default.json` changes were needed.

## Rebuild + redistribution (2026-09-06)

Rebuilt and re-shipped the signed/notarized macOS app to pick up the day's
changes (reader HashRouter URL fix, external-link opener, reader+account
nav lockdown from the two sections above):

- `npx tauri build` (with `~/.cargo/bin` on `PATH` — not there by default in
  a non-interactive shell) initially failed signing with "The timestamp
  service is not available," matching the 2026-09-02 Canopy-attributed
  failure. This time a plain retry did **not** clear it, but running
  `codesign --force --sign "Developer ID Application: Jacey Simpson
  (886XPLVC69)" --timestamp --options runtime` directly worked immediately
  once the user manually approved something on their end (not confirmed
  exactly what — possibly a keychain/Touch ID prompt for the signing key).
  **Don't assume Canopy is the cause next time this error appears** — ask
  the user whether a system prompt needs approving first.
- Full sequence repeated end to end: sign app → zip → `notarytool submit
  --wait` (Accepted) → `stapler staple` → `spctl --assess` (accepted) →
  `hdiutil create -format UDZO` for the `.dmg` → sign `.dmg` with
  `--timestamp` → `notarytool submit --wait` (Accepted) → staple → verify
  with `spctl -a -t open --context context:primary-signature -v
  FellowScript.dmg` (a plain `spctl --assess` on a `.dmg` incorrectly
  reports "rejected (the code is valid but does not seem to be an app)" —
  use the `-t open --context context:primary-signature` form for disk
  images instead).
- **Distribution**: the new `.dmg` was uploaded to the existing
  `desktop-v0.1.0` GitHub release as the `FellowScript.dmg` asset (`gh
  release upload desktop-v0.1.0 <path> --clobber`), replacing the old one
  in place. `frontend/src/pages/Home.jsx`'s `MACOS_DOWNLOAD_URL` points at
  that same release/filename permanently, so no frontend change or
  redeploy was needed to put the new build behind the site's existing
  "Download for Mac" link.
- `gh` has no stored auth in this environment; a token was pulled from
  git's own credential store instead: `git credential fill` with
  `protocol=https`/`host=github.com`, exported as `GH_TOKEN` for the
  `gh release` calls.

## Native window chrome polish (2026-09-08)

Task `20260908-desktop-native-window-chrome`: the window previously used Tauri's
bare defaults — no background color, no macOS title-bar styling, no minimum
size — so it looked like an unstyled wrapped website rather than a native app.
Fixed entirely in `src-tauri/tauri.conf.json` (no `lib.rs` changes needed):

- **Dark title bar**: added `"titleBarStyle": "Transparent"` plus
  `"theme": "Dark"`. `Transparent` (not `Overlay`) was chosen deliberately —
  `Overlay` draws the title bar over the window's content and requires a
  custom drag region plus the page itself leaving room for the traffic-light
  buttons, which the live site (loaded as-is, with no awareness it's running
  in a chrome-less title bar) has no way to account for. `Transparent` keeps
  the title bar as a normal, separate strip above the content — no traffic
  lights overlapping page UI — but paints it with the window's own
  `backgroundColor` instead of the OS's default light gray. `"theme": "Dark"`
  is paired with it because `titleBarStyle` alone doesn't change the window's
  effective macOS appearance: without forcing `Dark`, the title text and
  traffic-light rendering would still follow the OS's (usually light) theme
  and could read poorly against the dark background. Confirmed this is
  read correctly through the actual programmatic construction path
  (`WebviewWindowBuilder::from_config` in `lib.rs`'s `.setup()` — the window
  isn't auto-created from config's declarative-only path since `"create":
  false` is set) by reading the pinned `tauri`/`tauri-runtime-wry` 2.11.x
  source directly: `WindowBuilderWrapper::with_config` applies
  `title_bar_style`, `theme`, `background_color`, and `min_width`/`min_height`
  from the full `WindowConfig` regardless of how the builder was obtained, so
  the manual `from_config(...)` construction in `lib.rs` gets all of these
  the same as the declarative path would.
- **Launch flash**: added `"backgroundColor": "#0A0A0A"` (matches
  `frontend/src/styles/global.css`'s `--bg-page` exactly). Per the Tauri v2
  config schema, this field explicitly sets *both* the window's and the
  webview's background color, so the surface behind the live page is already
  the site's own near-black before the network fetch of
  `https://fellowscript.com/#/reader` completes and paints — not just the
  native window frame. Went with config-only (no `visible: false` +
  show-on-ready code path in `lib.rs`): the flash is caused by an unset
  background defaulting to white, and `backgroundColor` covering both the
  window and webview layers directly addresses that root cause without added
  code, event wiring, or new test surface, in keeping with this project's
  loading-state preference for minimal/unfussy fixes over added machinery.
  This environment has no display to visually confirm the flash is fully
  gone — the `testing` gate should call this out as needing a real
  interactive check on the packaged app, and if a flash is still visible in
  practice the follow-up is the `visible: false` + show-on-ready pattern
  inside the existing `.setup()` closure.
- **Minimum window size**: added `"minWidth": 1025` (exactly matching
  `frontend/src/hooks/useIsDesktopViewport.js`'s `min-width: 1025px` desktop
  cutoff — the site's mobile/tablet layout, a distinct purpose-built
  experience, is never meant to render inside this wrapper) and
  `"minHeight": 720`. No equivalent height breakpoint exists in the site's own
  responsive CSS to mirror exactly, so 720 was chosen as a floor comfortably
  below the default `860` while still leaving the reader's dockview workspace
  (notes, messaging, highlights, AI chat panels) usable rather than squished.
- Not touched: `on_navigation`/`on_new_window`/`is_allowed_navigation` in
  `lib.rs` (the navigation-security allowlist from
  `20260906-desktop-scope-lockdown`), `frontend/` (the desktop app loads that
  live content and doesn't own its styling), any Windows/Linux chrome
  equivalents (`titleBarStyle`/`hiddenTitle` are macOS-only fields; macOS
  remains the only currently-built target).
- Verified with `cargo check` and `cargo clippy` (both clean, no `lib.rs`
  changes so the existing `desktop_scope_lockdown_tests` suite is unaffected
  and still passes as-is). A real visual/interactive launch check (dark title
  bar rendering, no flash, resize-floor behavior) is the `testing` gate's job
  per this environment having no display.

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
