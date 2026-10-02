# FellowScript

**A Digital Scripture Community — Read · Reflect · Connect**

FellowScript is a faith-based Bible study platform for reading scripture, taking rich notes, connecting with a study group, and receiving AI-powered devotional check-ins. It runs as a React web app and a native iOS app, both backed by a shared FastAPI + Postgres server hosted on AWS EC2.

---

## Core Features

| Feature | Description |
|---|---|
| Digital Bible | Navigate all 66 books by chapter with a clean, typeset reading view |
| Highlighting | Mark verses in six colors; highlights persist per user |
| Rich Notes | Add formatted notes (bold, italic, underline, highlight, color) linked to one or more verses |
| Bookmarks | Bookmark chapters for quick return |
| Groups | Create or join study groups; share public notes and highlights within the group |
| Friends | Send/accept friend requests; start direct messages |
| Group & Direct Messaging | Real-time WebSocket chat — group threads and 1-on-1 DMs |
| Devotions | Collaborative devotion plans shared across a group |
| Scheduled devotions | Pick a time and a prompt; every day at that time your AI study partner writes a devotion for you, even when the app is closed (internal name: agent heartbeats) |
| Notifications | In-app notifications for group activity and your scheduled devotions |
| Subscriptions | Free tier (5 notes per week, 1 scheduled devotion in total) + Individual and Group paid plans via Stripe (web) or Apple IAP (iOS) |
| Account | Profile management and account deletion for web and iOS |

### Naming: user-facing term vs. internal identifiers

Users see "scheduled devotions". The internal names below are public identifiers (API
routes and fields, database columns, Swift/JS symbols, analytics keys) and are deliberately
**not** renamed, so older app builds keep working.

| User-facing term | Internal identifier |
|---|---|
| Scheduled devotions (usage meter label, plan limit) | `agent_events` (usage/limit resource key) |
| A single scheduled devotion | `agent_heartbeats` row, `FSHeartbeat` / `heartbeats` in client code |
| Create, edit, delete, "write it now" | `/agent/{user_id}/...heartbeat...` routes (e.g. `commit_heartbeat`) |
| Free plan: 1 scheduled devotion in total, paid plans unlimited | `FREE_LIMITS["agent_events"] = 1` |

Copy guidelines: label "Scheduled devotions", sentence "scheduled devotion", creation button
"New scheduled devotion". Avoid "agent", "event", "heartbeat" and "automation" in user-facing text
for this feature. Examples to use: morning devotion, evening prayer prompt, weekly recap,
reading-plan check-in.

---

## Pages (Web)

| Route | Page |
|---|---|
| `/` | Home — landing page with feature overview and pricing |
| `/reader` | Bible Reader — scripture, notes sidebar, messaging sidebar |
| `/account` | Account — profile, subscription card, danger zone |
| `/signin` | Sign In / Sign Up — password, Google, or Apple |
| `/privacy` | Privacy Policy |
| `/terms` | Terms of Service |

---

## Clients

- **Web** — React + Vite SPA, deployed via rsync to Nginx on EC2
- **iOS** — Native Swift app (Xcode), distributed via App Store

---

## Design at a Glance

| Token | Value |
|---|---|
| Background | `#1a140f` (warm near-black) |
| Primary accent | `#e8a53d` / `#c8861a` (warm gold) |
| Parchment text | `#f4e4c1` |
| Heading fonts | Playfair Display, Space Grotesk |
| Body / note fonts | Lora, IM Fell English |
| Code / mono | JetBrains Mono |
