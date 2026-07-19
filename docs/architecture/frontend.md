# Frontend

The web frontend is a **React 18 + Vite** single-page application in `frontend/src/`. Routing uses `react-router-dom` with `HashRouter` (`/#/` prefix). UI components come from **Ant Design**. The built output in `frontend/dist/` is deployed to EC2 `/var/www/html/` via rsync.

---

## Pages

| Route | File | Description |
|---|---|---|
| `/` | `pages/Home.jsx` | Public landing page — hero, features, pricing, CTA |
| `/reader` | `pages/Reader.jsx` | Bible reader with notes and messaging sidebars |
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
| `NotesSidebar.jsx` | Full notes panel: Notes tab (rich-text cards sorted by creation date), Highlights tab, filter/sort panel, in-line editor |
| `MessagingSidebar.jsx` | Real-time WebSocket messaging — group chat and 1-on-1 DMs |
| `BibleCard.jsx` | Renders a single verse with inline highlight color, click-to-highlight, and verse selection |
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

The Reader page uses a three-panel CSS grid:

```
┌─────────────┬──────────────────────┬──────────────┐
│  AppNav     │                      │              │
│  (sidebar   │   Scripture text     │   Notes or   │
│   on left)  │   BibleCard × verse  │   Messaging  │
│             │   BibleNavigator     │   sidebar    │
└─────────────┴──────────────────────┴──────────────┘
```

On narrow screens the sidebars collapse and are accessed via toggle buttons above the scripture view.

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
