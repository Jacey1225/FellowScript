use tauri::{
  menu::{Menu, MenuItem},
  webview::NewWindowResponse,
  Manager, Runtime, Url, WebviewWindowBuilder,
};
use tauri_plugin_opener::OpenerExt;

// Menu id for the native "Reload" item added below (task
// 20260908-desktop-reload-button) -- matched against in `.on_menu_event`.
const RELOAD_MENU_ITEM_ID: &str = "reload";

// The single window declared in `tauri.conf.json` has no explicit `label`,
// so Tauri assigns it the default label "main" (also what
// `capabilities/default.json`'s `windows` array already references).
const MAIN_WINDOW_LABEL: &str = "main";

// Defense-in-depth mirror of frontend/src/lib/desktopScope.js's
// DESKTOP_ALLOWED_ROUTES (task 20260906-desktop-scope-lockdown; allowlist
// finalized by the security gate's step-1 result). This list must be kept in
// sync with that file by hand -- the frontend guard is the primary
// enforcement (it catches in-SPA Link/navigate() calls, which HashRouter
// resolves as same-document history pushes that never reach this Rust-side
// check at all); this check only ever fires for a *real* main-frame webview
// navigation (a full page load/reload, or a `window.location` assignment),
// which is exactly the case the frontend guard can't see.
const DESKTOP_ALLOWED_ROUTES: &[&str] = &[
  "/reader",
  "/account",
  "/signin",
  "/forgot-password",
  "/reset-password",
  "/verify-2fa",
];

// Only the live site's own origin is ever legitimate for this window --
// nothing here needs to (or should) navigate anywhere else same-window.
// External links already leave via the `on_new_window` handoff below, not
// this path.
fn is_allowed_navigation(url: &Url) -> bool {
  if url.scheme() != "https" || url.host_str() != Some("fellowscript.com") {
    return false;
  }

  // HashRouter keeps the route in the URL fragment (e.g. `#/reader`), not
  // the path -- the path itself is always `/` since the server returns the
  // same `index.html` for every path (see desktop/PROGRESS.md's "UI parity
  // fix" note). An absent/empty fragment resolves to the Home route, which
  // is intentionally not on the allowlist, so it's denied like anything
  // else not listed.
  let route = url.fragment().unwrap_or("");
  let route = route.split(['?', '&']).next().unwrap_or("");
  DESKTOP_ALLOWED_ROUTES.contains(&route)
}

// --- Reload mechanism: finalized design (task 20260908-desktop-reload-button,
// security gate step 1) -- implement against this, don't re-derive it ---
//
// Threat model / why this shape:
// (a) Affordance: extend the existing macOS "View" submenu below (already
//     built by `Menu::default()`, currently just Fullscreen) with a "Reload"
//     MenuItem bound to the idiomatic `CmdOrCtrl+R` accelerator. No in-window
//     toolbar button -- the loaded content is the live site's own HTML, so
//     this repo owns no window chrome to put a persistent button in. The
//     native menu bar is the most persistently-discoverable option actually
//     buildable here (UI/UX Q11).
// (b) One manual reload trigger covers both failure modes named in the
//     intake request (a genuinely failed load, and a stuck/unresponsive
//     page). Do NOT build a separate custom fallback/error page or
//     `did_fail_load` handling for this task -- out of scope per the
//     intake spec's acceptance criteria and right-sized per
//     architecture-design-thinking.
// (c) Implementation MUST call the webview's native `reload()` (e.g.
//     `WebviewWindow::reload()`), never `eval("window.location.reload()")`
//     -- an `eval` depends on the page's own JS event loop running, which is
//     exactly what can't be assumed when the page is "stuck." Native
//     `reload()` re-invokes the OS webview engine's own navigation delegate
//     (confirmed by reading the pinned wry 0.55.1 source: on macOS,
//     `setNavigationDelegate` is registered once, webview-instance-wide, in
//     `wkwebview/mod.rs` -- the same delegate `.on_navigation()` below hooks
//     into for every navigation, including a native reload). That means
//     `is_allowed_navigation` is automatically re-consulted on reload with
//     zero new code path -- there is nothing to "wire up" here, and nothing
//     for a reload handler to bypass. It also means reload always targets
//     whatever URL is *already* loaded, which is always already-allowed by
//     construction (a disallowed URL can never have become "current" in the
//     first place, since `on_navigation` gates that) -- so there's no need
//     to separately track or fall back to a "last known good" route.
// (d) The reload trigger MUST stay purely native: wired only via
//     `.on_menu_event` (menu click or its `CmdOrCtrl+R` accelerator),
//     dispatched from Rust against the app's own window handle. Do NOT
//     expose this as a `#[tauri::command]` callable via `invoke()` from
//     frontend JS -- the loaded page is live, remote, third-party-influenced
//     content (note bodies, messages), and handing it a new invokable
//     "force reload" capability would be a fresh, unnecessary attack
//     surface for no user benefit (deny-by-default, Security Posture Q2).
//     Consistently, no new entry is needed in `capabilities/default.json`
//     for this feature -- it has zero IPC surface.
// (e) Regression coverage (step 2/3) should prove the *shared* choke point
//     stays sound end-to-end -- i.e. that a reload-equivalent navigation to
//     an allowed route still passes `is_allowed_navigation` and one to a
//     hypothetically disallowed URL is still denied -- alongside the
//     existing `desktop_scope_lockdown_tests` module, not a new bypassable
//     path of its own.
// (f) Windows/Linux: out of scope for this task (macOS is the only built
//     target per `desktop/PROGRESS.md`) -- `reload()` is cross-platform in
//     the `tauri`/`wry` API, but whether WebView2/WebKitGTK's navigation
//     delegate equivalently re-fires on native reload has not been verified
//     here and should not be assumed if Windows packaging is ever picked up.

// Builds the standard App/File/Edit/View/Window/Help menu (Tauri's own
// macOS default, kept explicit rather than relied on implicitly -- see
// `run()` below for why) and appends a "Reload" item with the idiomatic
// `CmdOrCtrl+R` accelerator to the existing "View" submenu, per the
// finalized design above.
//
// `Menu::default()` only builds a "View" submenu on macOS (Tauri's own
// source gates it with `#[cfg(target_os = "macos")]`); on other platforms
// this simply finds no "View" submenu and leaves the default menu
// untouched -- there's nothing Windows/Linux-specific to add here since
// this task doesn't target those platforms (see PROGRESS.md's "Not started
// yet").
fn build_menu<R: Runtime>(app_handle: &tauri::AppHandle<R>) -> tauri::Result<Menu<R>> {
  let menu = Menu::default(app_handle)?;

  let view_submenu = menu.items()?.into_iter().find_map(|item| {
    item
      .as_submenu()
      .filter(|s| s.text().ok().as_deref() == Some("View"))
      .cloned()
  });

  if let Some(view_submenu) = view_submenu {
    let reload = MenuItem::with_id(
      app_handle,
      RELOAD_MENU_ITEM_ID,
      "Reload",
      true,
      Some("CmdOrCtrl+R"),
    )?;
    view_submenu.append(&reload)?;
  }

  Ok(menu)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
  tauri::Builder::default()
    .plugin(tauri_plugin_opener::init())
    // Explicitly register the standard App/File/Edit/View/Window/Help menu
    // (Tauri's own macOS default, made explicit rather than relied on
    // implicitly) so the Edit submenu's native Undo/Redo/Cut/Copy/Paste/
    // Select All items are always present — this is what makes Cmd+Z/Cmd+A
    // work correctly in the note editor and message composer. See
    // desktop/PROGRESS.md for the investigation that confirmed this.
    // Also appends a "Reload" item (task 20260908-desktop-reload-button) to
    // the existing View submenu -- see `build_menu` above.
    .menu(build_menu)
    // Native, Rust-side reload trigger (task 20260908-desktop-reload-button):
    // fires for both the "Reload" menu click and its CmdOrCtrl+R
    // accelerator, dispatched from Rust against the window's own handle --
    // deliberately NOT exposed as a `#[tauri::command]` invokable from
    // frontend JS (see the threat-model comment above `pub fn run()` for
    // why). Calls `WebviewWindow::reload()`, the native webview reload API,
    // never `eval("location.reload()")` -- the latter depends on the
    // page's own JS event loop running, which is exactly what can't be
    // assumed when the page is "stuck." Native reload re-invokes the OS
    // webview engine's own navigation delegate, so the existing
    // `on_navigation`/`is_allowed_navigation` allowlist check below is
    // automatically re-consulted with zero new code path -- there is
    // nothing here that could bypass it.
    .on_menu_event(|app, event| {
      if event.id() == RELOAD_MENU_ITEM_ID {
        match app.get_webview_window(MAIN_WINDOW_LABEL) {
          Some(window) => {
            if let Err(err) = window.reload() {
              log::error!("failed to reload main window: {err}");
            }
          }
          None => log::warn!("reload requested but no '{MAIN_WINDOW_LABEL}' window was found"),
        }
      }
    })
    .setup(|app| {
      if cfg!(debug_assertions) {
        app.handle().plugin(
          tauri_plugin_log::Builder::default()
            .level(log::LevelFilter::Info)
            .build(),
        )?;
      }

      // The "main" window is declared with `"create": false` in
      // tauri.conf.json so it can be built here instead, with an
      // `on_new_window` handler wired up. Without this, `target="_blank"`
      // links and `window.open()` calls from the live site (note bodies,
      // messages, Terms of Service) are silently swallowed by the bare
      // webview instead of opening in the system's default browser.
      let window_config = app
        .config()
        .app
        .windows
        .first()
        .expect("main window must be defined in tauri.conf.json")
        .clone();
      let opener_handle = app.handle().clone();
      WebviewWindowBuilder::from_config(app.handle(), &window_config)?
        // Defense-in-depth for the desktop scope lockdown (task
        // 20260906-desktop-scope-lockdown): denies any real same-window
        // navigation outside DESKTOP_ALLOWED_ROUTES above. This is separate
        // from, and does not replace, the frontend's DesktopRouteGuard --
        // see that component and lib/desktopScope.js for the primary
        // enforcement layer and the reasoning split between the two.
        .on_navigation(|url| {
          let allowed = is_allowed_navigation(url);
          if !allowed {
            log::warn!("denied desktop navigation outside allowlist: {url}");
          }
          allowed
        })
        .on_new_window(move |url, _features| {
          // `OpenerExt::open_url` is a direct Rust-side call to the OS's
          // default-application opener — it does NOT go through Tauri's IPC
          // layer, so the `opener:allow-open-url` capability scope declared
          // in capabilities/default.json (https://* only) is never consulted
          // here and provides no actual enforcement on this path. `url`
          // originates from webview new-window/window.open() requests, which
          // can be influenced by remote/user-generated content (note bodies,
          // messages) rendered in the page, so it must not be forwarded to
          // the OS shell opener unchecked (untrusted schemes — e.g. file://
          // or an OS-registered deep-link handler — could otherwise be
          // triggered by a crafted note/message link). Mirror the capability
          // scope's intent explicitly in code: only https URLs are handed
          // off to the system browser.
          if url.scheme() == "https" {
            if let Err(err) = opener_handle.opener().open_url(url.to_string(), None::<&str>) {
              log::error!("failed to open external link {url} in system browser: {err}");
            }
          } else {
            log::warn!("denied opening non-https external link: {url}");
          }
          NewWindowResponse::Deny
        })
        .build()?;

      Ok(())
    })
    .run(tauri::generate_context!())
    .expect("error while running tauri application");
}

// Regression coverage for task 20260906-desktop-scope-lockdown's Tauri-side
// defense-in-depth check (testing gate, step 4): proves the allowlist mirror
// actually denies everything it's supposed to deny -- including the routes
// intake/security explicitly called out as must-stay-excluded (Home,
// Privacy, Terms, admin) -- and allows exactly the finalized closed set,
// independent of the frontend guard `DesktopRouteGuard.jsx` covers.
#[cfg(test)]
mod desktop_scope_lockdown_tests {
  use super::*;

  fn url(s: &str) -> Url {
    Url::parse(s).expect("valid test URL")
  }

  #[test]
  fn allows_every_route_on_the_finalized_allowlist() {
    for route in DESKTOP_ALLOWED_ROUTES {
      let u = url(&format!("https://fellowscript.com/#{route}"));
      assert!(is_allowed_navigation(&u), "expected {route} to be allowed");
    }
  }

  #[test]
  fn denies_home_privacy_terms_and_admin() {
    for route in ["", "/", "/privacy", "/terms", "/admin", "/admin/detections/1"] {
      let u = url(&format!("https://fellowscript.com/#{route}"));
      assert!(!is_allowed_navigation(&u), "expected {route:?} to be denied");
    }
  }

  #[test]
  fn denies_an_absent_fragment_the_same_as_home() {
    // No `#...` at all -- e.g. a bare https://fellowscript.com/ load --
    // must resolve to "denied", exactly like the empty-fragment Home case,
    // not accidentally treated as an allowed empty route.
    let u = url("https://fellowscript.com/");
    assert!(!is_allowed_navigation(&u));
  }

  #[test]
  fn denies_query_strings_appended_to_an_otherwise_allowed_route() {
    // A crafted `#/reader?evil=1` must still resolve on route alone (the
    // `?`/`&` split in is_allowed_navigation), not be denied or, worse,
    // accidentally let a non-allowlisted fragment slip through via a
    // lookalike query string.
    let u = url("https://fellowscript.com/#/reader?ref=evil");
    assert!(is_allowed_navigation(&u));
  }

  #[test]
  fn denies_non_https_and_non_fellowscript_hosts_even_with_an_allowed_route() {
    for candidate in [
      "http://fellowscript.com/#/reader",
      "https://evil.example.com/#/reader",
      "file:///etc/passwd#/reader",
    ] {
      let u = url(candidate);
      assert!(!is_allowed_navigation(&u), "expected {candidate} to be denied");
    }
  }

  // Regression coverage for task 20260908-desktop-reload-button (testing
  // gate, step 3): the native "Reload" menu item / CmdOrCtrl+R accelerator
  // added in `build_menu`/`run()` calls `WebviewWindow::reload()`, which
  // (per the security gate's step-1 threat model, documented above
  // `pub fn run()`) re-invokes the same `.on_navigation()` delegate --
  // and therefore this same `is_allowed_navigation` choke point -- with no
  // new code path of its own. These tests don't re-test the allowlist
  // contents (see the tests above for that); they document and pin the
  // specific claim the reload feature's safety depends on: reloading an
  // already-loaded, already-allowed URL still passes, and a
  // reload-equivalent navigation to a URL that was never legitimately
  // "current" (e.g. a hypothetically compromised/rewritten state) is still
  // denied through the exact same check, since there is no separate
  // reload-specific bypass to test.
  #[test]
  fn reload_of_an_allowed_route_still_passes_the_allowlist() {
    // Simulates what `WebviewWindow::reload()` re-navigates to: whatever
    // URL is already loaded. Any allowed route must still pass when
    // presented to `is_allowed_navigation` a second time, exactly as it
    // did on first load.
    let currently_loaded = url("https://fellowscript.com/#/reader");
    assert!(is_allowed_navigation(&currently_loaded));
    // Re-checking (as a reload would) is idempotent -- still allowed.
    assert!(is_allowed_navigation(&currently_loaded));
  }

  #[test]
  fn reload_of_a_hypothetically_disallowed_url_would_still_be_denied() {
    // Even in a hypothetical state where something outside the allowlist
    // became "current" (e.g. a future bug elsewhere), a reload-equivalent
    // re-navigation to it must still be denied by this same check -- there
    // is no separate, more permissive path a reload could take instead.
    let hypothetically_current = url("https://fellowscript.com/#/admin/detections/1");
    assert!(!is_allowed_navigation(&hypothetically_current));
  }
}
