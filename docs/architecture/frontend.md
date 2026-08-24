# Frontend

The web frontend is a **React 18 + Vite** single-page application in `frontend/src/`. Routing uses `react-router-dom` with `HashRouter` (`/#/` prefix). UI components come from **Ant Design**. The built output in `frontend/dist/` is deployed to EC2 `/var/www/html/` via rsync.

---

## Pages

| Route | File | Description |
|---|---|---|
| `/` | `pages/Home.jsx` | Public landing page — hero, features, pricing, CTA |
| `/reader` | `pages/Reader.jsx` | Bible reader — desktop: dockable VSCode-style panel workspace; mobile: bottom-tab-bar overlays |
| `/account` | `pages/Account.jsx` | Profile, subscription card, danger zone |
| `/signin` | `pages/SignIn.jsx` | Password, Google, and Apple sign-in/sign-up |
| `/privacy` | `pages/Privacy.jsx` | Privacy policy |
| `/terms` | `pages/Terms.jsx` | Terms of service |
| `/admin` | `pages/AdminDetections.jsx` | **Hidden, admin-only.** CloudWatch error-detection feed — filter by log group/time range, paginated list of `ErrorDetection` rows. Not linked from `AppNav` or anywhere else in the UI; reachable only by navigating to the URL directly. Gated by `AdminGate` (client-side, defense-in-depth) plus the server-side `require_admin` dependency on every `/monitoring/*` endpoint, which is the actual enforcement boundary. Desktop (>1024px) renders rows as a fixed-column CSS Grid (`28px 160px 140px 130px 1fr 20px`) for dense columnar alignment. Mobile (≤1024px) falls back to a two-line row (status/log-group on line 1, demoted matched-signal + message on line 2) and replaces the desktop filter bar with a horizontally-scrollable chip-filter strip (log-group pills + a "Time" pill opening an anchored `Popover` with the From/To date pickers). Tapping a row on mobile opens `DetectionDetailOverlay` as a fullscreen overlay on top of the still-mounted list instead of navigating away — no `history.pushState`, so the URL stays `/admin` and a mobile hard refresh/direct link does not restore the overlay (accepted tradeoff for this hidden, low-volume ops surface). Desktop taps still navigate to `/admin/detections/:id`. |
| `/admin/detections/:id` | `pages/AdminDetectionDetail.jsx` | **Hidden, admin-only.** One detection's raw error + collapsible CloudWatch context, plus the debugging agent's persisted diagnostic report (root cause + remediation narrative), with a Generate/Rerun action that surfaces 429 rate-limit feedback (client-side cooldown) distinctly from a 502 OpenRouter failure. Same `AdminGate` + `require_admin` gating as `/admin`. Unchanged at any width — reachable via direct navigation/refresh, but no longer how mobile reaches detail from the `/admin` list (see `DetectionDetailOverlay` below). A "Download Remediation Instructions" button next to the Generate/Rerun action assembles a single Markdown handoff file (error record, raw context, diagnostic report if one exists) entirely client-side via `lib/remediationMarkdown.js` and triggers a browser download; a fire-and-forget `POST .../report/download-audit` call logs the export server-side without blocking or gating the download itself. Stays enabled with no report yet generated, producing an error-only file. |

Unauthenticated users land on Home (`/`); once signed in, the CTA routes directly to `/reader`.

---

## Key Components

| Component | Description |
|---|---|
| `AppNav.jsx` | Persistent top navigation bar — logo (links to `/`), reader link, account link; collapses to a drawer on narrow screens |
| `NotesSidebar.jsx` | Combined Notes+Highlights tabbed sidebar — **mobile only**; desktop uses the split `NotesPanel`/`HighlightsPanel` below |
| `BibleCard.jsx` | Renders a single verse with inline highlight color, click-to-highlight, and verse selection |
| `panels/BibleReaderPanel.jsx` | Desktop dockview panel: bundles `BibleNavigator` + font-size ticker + `BookmarkButton` + `BibleCard` + `HighlightPicker` in one component, so they always travel together wherever the panel is docked |
| `panels/NotesPanel.jsx` / `panels/HighlightsPanel.jsx` | Desktop dockview panels — the Notes and Highlights tabs of `NotesSidebar` split into independently dockable panels; each keeps its own copy of the group-selector dropdown |
| `panels/MessagingPanel.jsx` / `panels/AgentChatPanel.jsx` | Desktop dockview panels — friends/group DMs and the AI spiritual-guide chat, split apart so each can be positioned independently (previously combined behind one "Group" toggle) |
| `ContactsPanel.jsx` / `ChatThread.jsx` / `AgentChatThread.jsx` | Shared building blocks used by both the desktop panels above and the mobile fullscreen overlays |
| `BibleNavigator.jsx` | Book + chapter picker (search + scroll) |
| `ScriptureNav.jsx` | Prev/next chapter controls |
| `HighlightPicker.jsx` | Color swatch row for choosing the active highlight color |
| `BookmarkButton.jsx` | Toggle bookmark on the current chapter |
| `RichText.jsx` | `NoteBody` renderer for saved HTML notes; `stripHtml` utility |
| `VerseSelector.jsx` | Verse picker used inside the note editor to link verses |
| `SubscriptionCard.jsx` | Displays current plan (free tier vs. paid), usage limits, upgrade prompt |
| `SessionWidget.jsx` | Devotion session UI |
| `SessionCreator.jsx` | Create a new devotion plan |
| `DonationButton.jsx` | One-time donation flow |
| `AdminGate.jsx` | Wraps the two hidden `/admin*` routes. Handles only the synchronous "no session at all" redirect to `/signin`; the 401 (session expired)/403 (non-admin) cases are handled by each admin page's own first data fetch, since there's no client-visible `is_admin` field to check ahead of time — defense-in-depth UX only, not a security boundary. |
| `DetectionDetailOverlay.jsx` | Mobile-only (≤1024px) "list-overlay drawer" for a detection's detail, rendered by `AdminDetections.jsx` and reusing the `.mobile-overlay` slide-up CSS class. Duplicates (rather than shares) `AdminDetectionDetail.jsx`'s fetch/rerun-report logic so that page's desktop behavior stays untouched. Splits content into an antd `Segmented` "Error"/"Report" toggle (a status dot on "Report" indicates whether one has been generated) instead of stacking both cards, since a phone screen doesn't have room for both at once. Its Report panel has the same icon-only "Download Remediation Instructions" button as the desktop page (also duplicated rather than shared, calling the same `lib/remediationMarkdown.js` helper and audit endpoint independently). |

---

## State and Auth

`context/AuthContext.jsx` provides `useAuth()` across the app. It exposes:
- `user` — the logged-in user object (or `null`)
- `signIn(userData)` — stores user in context + `localStorage`
- `signOut()` — clears context + `localStorage`, redirects to `/signin`

Session persistence uses `localStorage`; the `user_id` cookie set by the server is used for API calls.

---

## Reader Layout

**Desktop** (viewports >1024px) uses [`dockview-react`](https://github.com/mathuo/dockview) to give the Reader page a VSCode-style dockable workspace: five independently-registered panels (Bible Reading, Notes, Highlights, Messaging, Agent Chat) that the user can drag to any edge (split), drop onto another panel (tab together), or resize. Key pieces, all under `frontend/src/`:

- `lib/readerDockLayout.js` — `buildDefaultLayout(api)` (the single source of truth for the default arrangement: Bible reader filling the main area, Notes+Highlights+Messaging tabbed on the right spanning full height, Agent Chat docked below the reader only), plus `loadSavedLayout`/`saveLayout`/`resetLayout` for persistence to `localStorage['fs_reader_layout_v1']` (debounced on `api.onDidLayoutChange`, versioned so a future panel-set change can invalidate old saved layouts).
- `context/ReaderPanelContexts.jsx` — five separate React contexts (one per panel), not dockview's own `params` mechanism (which only refreshes via an explicit imperative call) — `Reader.jsx` lifts all the data-fetching hooks (`useBible`, `useNotes`, `useMessaging`, `useAgentChat`, etc.) and feeds each panel a memoized context value, so e.g. an incoming chat message never re-renders the Bible panel.
- `components/panels/*.jsx` — the five panel components registered with `DockviewReact` via a `components` map keyed by panel id.
- `hooks/useIsDesktopViewport.js` — reactively decides which branch to mount (aligned to the same 1024px breakpoint the mobile CSS media query uses), so resizing across it cleanly swaps the dockview tree for the mobile layout instead of leaving one mounted-but-hidden.
- `styles/reader-dock.css` — retints dockview's theme variables to the app's own dark/gold/parchment palette (loaded after `dockview-react/dist/styles/dockview.css` in `main.jsx` so the overrides win).

**Mobile** (≤1024px) keeps its own, entirely separate layout, untouched by the above: scripture text fills the screen with a bottom tab bar that opens Notes or Messages as a fullscreen overlay (`.mobile-tab-bar`/`.mobile-overlay` in `global.css`). The two layouts share the same underlying data hooks and several components (`ContactsPanel`, `ChatThread`, `AgentChatThread`, `NotesSidebar`) but render completely different component trees.

---

## Styling

- Dark background `#1a140f` (warm near-black)
- Primary gold `#e8a53d` / `#c8861a`, parchment text `#f4e4c1`
- Fonts loaded via Google Fonts: Playfair Display, Space Grotesk, Lora, IM Fell English, JetBrains Mono
- Ant Design components are dark-themed via `ConfigProvider`
- CSS variables (`--gold`, `--parchment`, `--bg`) defined on `:root` in `index.css`
- Inline React styles + embedded `<style>` blocks for component-level media queries

---

## iOS App

The native iOS client lives in `FellowScript/FellowScript/` (Swift / SwiftUI). It shares the same REST API as the web frontend. Key files:

| File | Responsibility |
|---|---|
| `Services/NetworkService.swift` | All API calls (notes, auth, highlights, user delete, etc.) |
| `Services/StoreKitManager.swift` | StoreKit 2 IAP for subscription purchases |
| `Auth/GoogleAuthSession.swift` | Google Sign-In integration |
| `Models/Models.swift` | `Codable` data models mirroring the backend schemas |
| `Account/AccountView.swift` | Profile display, subscription status, delete-account flow |
| `Chat/ChatThreadView.swift` | Message thread (header, grouped bubbles, composer), session banner/detail, and `SessionCreatorSheet` — the bottom-sheet scheduling flow. Warm-dark-bloom restyle (matching `ChatRootView.swift`'s existing redesign) backed by `Theme.swift` tokens; same WebSocket/`NetworkService` data flow as before. `SessionCreatorSheet`'s duration control is a fixed 15/30/45/60-minute segmented picker (`Chat/SegmentedDurationControl.swift`) rather than the previous free 5-minute-step picker — `time_end` is still computed client-side from `time_start` + the selected duration, since `FSSession` has no duration field of its own. |
| `Chat/PillButton.swift`, `Chat/MessageGroupRow.swift`, `Chat/SegmentedDurationControl.swift`, `Chat/ChipToggle.swift` | Shared restyled Chat components (amber-gradient pill buttons, Slack-style grouped message rows, the duration segmented control, chip toggles) — per-feature component files, no separate shared `Theme/Components/` folder |
| `LoadingScreen/LoadingScreenView.swift`, `LoadingScreen/loading-screen.mov` | App-startup loading screen: an `AVQueuePlayer`/`AVPlayerLooper`-driven, muted, looping video (`loading-screen.mov` — HEVC with alpha, 1080×1080, transcoded from the 205MB ProRes source in `data/`) shown between sign-in and the app's first-load data being ready. Falls back to a static branded placeholder if the asset fails to load/decode, and to a held representative frame (no playback) under `accessibilityReduceMotion`. |
| `Services/StartupCoordinator.swift` | Startup-readiness gate `ContentView` uses to decide when to swap `LoadingScreenView` for the main tab view. Owns the shared `NotesViewModel`/`BibleViewModel`/`ChatViewModel` instances used by the Notes/Bible/Chat tabs (account/user info is already resident on `AppState.currentUser`), races their existing `.load(service:userId:)` calls against a fixed 8s timeout, and reports ready on whichever finishes first — a still-pending source at timeout just falls through to that screen's own existing per-panel loading state rather than blocking the app open. |

Account deletion on iOS: the delete request is awaited before `signOut()` is called (correct async sequencing — no race condition).
