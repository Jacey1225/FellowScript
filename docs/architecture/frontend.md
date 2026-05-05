# Frontend

The frontend lives in `frontend/` and is responsible for all user-facing UI. It communicates with the backend via REST API calls and a WebSocket connection.

---

## Pages

### Home (`/`)
- Renders the landing page with the FellowScript hero, mission statement, and feature cards
- "Start Reading" button routes the user to `/reader`

### Bible Reader (`/reader`)
- Fetches scripture text from the API based on selected book/chapter
- Renders the highlight palette and applies user/community highlights inline
- Contains the bottom tab bar (Read / Notes / Community)

---

## Components

| Component | Description |
|---|---|
| `NavBar` | Top bar with home link, title, and overflow menu |
| `HeroSection` | Home page hero with title, tagline, and CTA |
| `FeatureCards` | 2×2 grid of feature highlights on the home page |
| `BookSearch` | Search bar for jumping to a book/chapter |
| `ScriptureView` | Renders verse-by-verse scripture with inline highlights |
| `HighlightPalette` | Color selector row (yellow, orange, green, pink, blue) |
| `BottomTabBar` | Read / Notes / Community tab switcher |
| `NotesList` | Notes tab — filter tabs, note cards, add-note form |
| `CommunityPanel` | Community tab — member list with DM buttons + group chat |
| `MemberRow` | Single member with avatar, name, activity status, DM button |

---

## Styling

- Dark background (`#1a1a2e`) with gold accent (`#C9A84C`)
- Fonts: Playfair Display (headings), Lora (body text)
- Mobile-first — all layouts stack vertically; sidebars do not exist
- Bottom tab bar replaces all sidebar navigation on mobile

---

## Real-Time

The frontend maintains a WebSocket connection to `backend/messaging/websockets.py`:
- Listens for group chat messages and renders them in the Community tab
- Listens for member activity updates and refreshes the member list
- Sends chat messages and outgoing DMs through the same connection
