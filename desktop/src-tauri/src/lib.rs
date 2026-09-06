use tauri::{menu::Menu, webview::NewWindowResponse, Url, WebviewWindowBuilder};
use tauri_plugin_opener::OpenerExt;

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
    .menu(Menu::default)
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
}
