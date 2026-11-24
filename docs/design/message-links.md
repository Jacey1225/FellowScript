# Clickable message links

`http://` and `https://` URLs in chat text (DM, group, thread, attachment captions, agent chat) are shown as links on web, desktop and iOS. Detection runs on the client at render time, so old messages work and the stored text is unchanged. No backend change.

**Rules (shared by web and iOS via `shared/linkify-fixtures.json`):** the scheme is required (no bare `example.com` or `www.`); a URL ends at whitespace, `<`, `>` or `"`; trailing `. , ; : ! ? '` stay plain text; a trailing `)`, `]` or `}` is dropped only when unbalanced. Other schemes (`javascript:`, `data:`, `file:`, `ftp:`) are never linked, including in AI markdown replies.

**Opening:** web uses a new tab (`rel="noopener noreferrer nofollow"`); the desktop shell hands new-window requests for http(s) URLs to the system browser; iOS opens the system browser. Links with userinfo, a raw IP, a non-default port or an international (IDN) host ask "You're leaving FellowScript" first and show the ASCII host.

Code: `frontend/src/lib/linkify.js`, `frontend/src/components/LinkifiedText.jsx`, `FellowScript/FellowScript/Models/FSLinkify.swift`, `desktop/src-tauri/src/lib.rs` (`is_openable_external_url`).
