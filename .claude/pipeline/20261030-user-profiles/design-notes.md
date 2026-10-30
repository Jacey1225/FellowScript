# Design notes: Profile screen (step 3, spec only)

Task 20261030-user-profiles. Gate: design. Nothing here is implemented. Items marked DECISION are in design.json with alternatives and need Jacey's approval before frontend/iOS steps start; the notes below assume the recommended option for each.

## Design language used
There is no `design-kit/` directory in this repo. The governing sources are `docs/design/overview.md`, iOS `Theme/Theme.swift` (+ `widgetCard()`, `warmBloomBackground()`, `FSFormScaffold/FSFormCard`, `AvatarView`), and web `theme.js`, `styles/forms.css` (`ff-*` form classes, `FormSkin`). The product is dark-only (no light variant exists); "dark mode first-class" is satisfied by matching it. No new tokens, colors, or fonts are introduced. Typography follows the existing system (Playfair for the name, Inter on iOS / Lora on web for body); no new typographic personality is proposed.

Contrast (computed against bgPage #1E1812): parchment text ~14:1; textSecondary (parchment @0.55) ~5:1 (AA); gold #D4922A ~6.7:1; error #E06060 ~4.9:1. Do NOT use textMuted (@0.28) for any meaningful text (bio hint, counter, chip labels); it fails AA. Gold-filled primary button uses ink #1A100A text (~6.9:1).

## Anatomy (all platforms, mobile-first)
Vertical stack, centered, 24pt/px side padding, 16/24 rhythm:
1. Nav bar: Back (web: same explicit Back control as Account, `navigate(-1)` guarded by history idx, fallback `/reader`; iOS: sheet Close / native pop) and an overflow "More options" button (44pt target) on the right for non-self profiles.
2. Identity block: avatar 96pt (existing `AvatarView` / antd `Avatar`; no photo = gold-tinted circle with initial, existing fallback), username in Playfair 22 (`fontDisplayMD`), relationship chip beneath (icon + text, never color only).
3. Bio block: plain text, Inter/Lora 16, textPrimary, line-height ~1.45, wraps, max 160 chars so it never needs truncation or "more". Rendered as text only (no links, no markup, no auto-linking).
4. Action row (see DECISION C): primary action and optional secondary, full width on mobile, side by side on web >=640px. Min 44x44.
5. Inline status line (errors, "couldn't refresh") under the actions, `role="status"`/`.accessibilityElement` polite.

Container: iOS `widgetCard()` for the identity+bio card over `warmBloomBackground()`; web `FormSkin` wrapper with the same card treatment, max-width ~480px centered.

## Visibility tiers (matches security D3, approved)
| Viewer | Sees |
|---|---|
| Stranger (signed in, not blocked/suspended) | avatar, username, relationship state. Bio block replaced by one quiet line: "Bio is shared with friends." |
| Friend | + bio. If bio empty: "No bio yet." (textSecondary) |
| Self | + bio and Edit control. If empty: "Add a short bio so friends know who you are." with an Add bio button |
| Blocked either way / suspended / nonexistent | 404 screen, identical for all three |

Never render email, ids, timestamps, or "blocked you" language anywhere.

## Relationship states and actions (non-self)
| State | Chip | Primary | Secondary | Overflow menu |
|---|---|---|---|---|
| none | none | Add friend | (none; Message is not offered, DMs are friends-only) | Block, Report |
| request_sent | "Request sent" (clock icon) | disabled "Request sent" | (none) | Block, Report |
| request_received | "Wants to be friends" | Accept | Decline (text button) | Block, Report |
| friends | "Friends" (check icon) | Message | (none) | Unfriend, Block, Report |
| self | none | (none) | Edit bio | none (Account is reached via AppNav/Account tab) |

- Add friend / Accept use the existing username-keyed endpoints (profile payload must include username). After success the state flips locally and is reconciled by a refetch. Sending feedback: button shows spinner + `aria-busy`, label unchanged width to avoid layout jump.
- Add friend result copy is deliberately uniform (D5): "Friend request sent." Failure copy is generic: "Couldn't send that right now. Please try again." 429: "Slow down a little and try again in a moment." Never "user not found", "blocked", or "already requested".
- Message opens the existing DM thread (web: `openChat` in Reader, so from the Profile route this navigates to `/reader` with the DM open; iOS: dismisses the sheet and opens the thread in ChatRoot).
- Report reuses `ReportUserSheet` (iOS) / `ReportUserModal` (web) unchanged, content_type `user`. Success toast reuses the existing copy ("Report submitted. We review every report within 24 hours.").
- Block reuses the existing destructive confirm ("Block {name}?" ... explains it removes friendship and hides profiles both ways). On confirm: call endpoint, clear this profile from the cache, navigate back (web Back / iOS dismiss), toast "{name} blocked." with Manage link to Blocked Users. Block auto-files a report server-side, so it cannot be undone in the sense of retracting that report; the toast offers "Undo" (calls unblock) only for the first 6s and the confirm dialog already warns. Honest label: "Unblock" not "Undo", so it does not imply the report is withdrawn.
- Unfriend (undo grace period): confirm-less, deferred commit. Tapping Unfriend shows a snackbar "Removed {name}. Undo" for 6s and only then calls DELETE (re-friending needs a new request, so server-side undo is impossible; the grace period is client-side deferral). Leaving the screen within the window commits immediately. Bio becomes hidden the moment the user taps Unfriend.

## Own profile and bio editing (DECISION E recommended: inline)
- "Edit bio" turns the bio block into a multiline text field in place (autofocus, `maxlength` not enforced by hard-stopping paste; paste is accepted then flagged so the user sees what was cut).
- Counter "n/160" always visible while editing, textSecondary; at <=20 remaining it turns gold with text "12 left"; over limit it turns error color AND shows "Over by 3", Save disabled. Counter is `aria-live="polite"`, announced only at thresholds (20, 0, over) to avoid chatter.
- Counted after trim; newlines collapse to single spaces on save (plain single-paragraph bio, per server normalization); plain text only; helper text: "Plain text, up to 160 characters. No links."
- Save / Cancel row. Cancel with unsaved changes asks nothing (draft is small) but Esc/swipe-down on iOS with dirty draft uses the existing `FSFormScaffold dirty:` discard confirm.
- Failure keeps the draft verbatim and shows the error inline under the field (never a modal, never clears the text): 422 filter rejection shows the server's warm message; 429 "You've edited a lot just now. Try again in a few minutes."; network "Couldn't save your bio. Your text is still here." Save re-enabled.
- Success: field collapses to display mode with a brief checkmark (static, no animation under reduced motion), bio announced "Bio saved".
- Account page: add only a single "View my profile" row linking here. Do not grow `Account.jsx` / `AccountView+Profile.swift` with edit UI.

## States
- Loading (first load, no cache): skeleton avatar circle + two shimmer lines + disabled action placeholder; shimmer replaced by static dim blocks under reduced motion. Never default/fake text.
- Loading (cache exists): show cached profile immediately, small inline "Updating..." line; no layout jump.
- Failed refresh with cache: keep cached profile, status line "Couldn't refresh. Showing what we had." + Retry. Exception (D10): if the failure is a 404, drop the cache and show the unavailable screen; cached bio is also dropped immediately on local block/unfriend. Cache never persists across sign-out.
- First load error, no cache: centered "Couldn't load this profile." + Try again; no fabricated profile.
- 404 / unavailable: "This profile isn't available." + Back. Same for nonexistent, blocked, suspended. No other detail.
- Action in flight: only that button shows busy; rest remain usable. Double-tap is ignored while busy.
- Offline: same as failed refresh; actions fail with generic copy and keep state.

## Accessibility and motion
- All targets >=44x44; visible focus ring (web `:focus-visible` gold 2px); full keyboard order: Back, More, primary, secondary, bio Edit.
- Overflow menu: web antd Dropdown (existing ContactRow pattern, `aria-label="More options for {name}"`); iOS `Menu` with labelled buttons. Block/Unfriend are destructive-styled with text, not only color.
- VoiceOver/screen reader reads: "{name}, {relationship}. Bio: {bio}." as one heading+text group; action buttons labeled "Add {name} as a friend", "Message {name}", "Accept friend request from {name}".
- Dynamic Type/zoom: layout reflows to a single column, buttons grow; no fixed heights. Username wraps to 2 lines max then truncates tail.
- Reduced motion: no shimmer, no spring; state changes are instant fades <=100ms or none. Use existing `withMotionAwareAnimation` (iOS) and `prefers-reduced-motion` (web).
- Errors always have text (not color-only) and are in a polite live region; focus returns to the triggering control after a sheet/modal closes.

## Per-platform notes
- iOS: new `Profile/ProfileView.swift` (+ small subviews), `ProfileViewModel`, `NetworkService+Profile.swift`. Presented from `ChatRootView` via `.sheet` or push per DECISION B; own profile via a row in Account. `AccountView+Profile.swift` (439 lines) and `ChatRootView` get entry-point wiring only.
- Web: `pages/Profile.jsx` + small components (`ProfileHeader`, `ProfileActions`, `BioEditor`). `ChatThread.jsx`/`ContactsPanel.jsx` get an `onViewProfile` hook only.
- Desktop (Tauri, same bundle): `lib/desktopScope.js` must allow the new route or `DesktopRouteGuard` redirects to `/reader`. Add a pattern entry like `^/profile/[0-9a-f-]{36}$` (UUID tail, same one-segment rule as `/join/`) plus a test in `desktopScope.test.js`. No other desktop change. This only applies if DECISION B web option 1 is approved.
- Entry from a group-member or DM header avatar passes user_id (already present); request-list rows pass the id from `get_requests`.
