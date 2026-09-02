# Home Page

The home page (`/`) is the public-facing landing page. It is visible to everyone — signed in or not — and serves as both the marketing entry point and the navigation hub for signed-in users.

---

## Sections (top to bottom)

### 1. Navigation Bar
- Left: FellowScript logo + wordmark (links back to `/`)
- Centre: nav links — Features, Community, Pricing
- Right: Sign In link + "Start Reading →" CTA button (gold)
- Signed-in users see "Go to Reader →" instead

### 2. Hero
- Tag line: `READ · REFLECT · CONNECT` in spaced gold caps
- Headline: large Playfair Display serif title
- Subheadline: short mission description
- CTA: "Begin Your Study →" (routes to `/reader` if signed in, `/signin` if not)
- Background: dot-grid pattern on `#1a140f`; floating "floating card" elements showing sample verse cards

### 3. How It Works (3-step strip)
- Step 1: Read — open any book and chapter
- Step 2: Reflect — add rich-text notes linked to specific verses
- Step 3: Connect — join a group and share insights in real time

### 4. Features Grid (6 cards)
| Feature | Description |
|---|---|
| Digital Bible | Full 66-book Bible with chapter navigation |
| Rich Notes | Formatted notes (bold, italic, highlight, color) linked to verses |
| Community Groups | Study groups with shared notes, highlights, and real-time chat |
| AI Check-Ins | Daily AI-generated devotional prompts and agent heartbeats |
| Highlights | Per-verse color highlights; group members' highlights visible in-context |
| Bookmarks | Quick-return bookmarks per chapter |

### 5. Community Spotlight
Mock group conversation showing the collaborative note/chat experience — sample study group discussing Romans 8.

### 6. Pricing (3-plan cards)
| Plan | Price | Limits |
|---|---|---|
| Free | $0 | 5 notes/week, limited agent events |
| Individual | $4.99/mo | Unlimited notes, agent events, notifications |
| Group | $9.99/mo | Everything in Individual + group management tools |

"Most popular" badge displayed on the Individual plan.

### 7. On Your Desktop
Two-card section between Pricing and the closing Quote CTA, offering the Tauri-based desktop app (a dedicated window onto the same live, cookie-authenticated reader — not an offline/bundled build).

- **macOS card** (primary, live): icon badge, "Signed, notarized, ready" title, one-line description, "Download for Mac" button, and a metadata line (architecture support + file size, no OS-version claim).
- **Windows card** (recessed, "Coming soon" badge): "Still in the workshop" title, description, platform-coverage line, metadata line — intentionally has no clickable control at all, by design (not a disabled button).

Both platform badges use the official `simple-icons` (MIT-licensed) Apple and Windows brand marks, not hand-authored approximations.

The macOS "Download for Mac" button now links live to the real GitHub Release asset (`desktop-v0.1.0/FellowScript.dmg`) — no longer a placeholder. Per the user's decision, no minimum-macOS-version claim is displayed at all; the metadata line shows only two verified facts: architecture support (Apple silicon & Intel) and file size (3 MB) from the actual built `.dmg`.

### 8. Quote CTA
Final call-to-action with 2 Timothy 1:6 as the closing verse, and a "Join FellowScript" button.

---

## Navigation from Home

| Element | Destination |
|---|---|
| Logo / title | `/` (home) |
| "Start Reading" / "Begin Your Study" | `/reader` (signed in) or `/signin` |
| Sign In link | `/signin` |
| Nav "Features", "Pricing" | Smooth scroll to section anchor |
