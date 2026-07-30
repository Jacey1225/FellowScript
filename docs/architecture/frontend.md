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

Account deletion on iOS: the delete request is awaited before `signOut()` is called (correct async sequencing — no race condition).
