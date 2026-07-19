# Design Overview

FellowScript's visual identity evokes the warmth and reverence of handwritten scripture — candlelight on parchment — while remaining clean and modern enough for everyday use.

---

## Visual Identity

| Token | Value | Usage |
|---|---|---|
| Background | `#1a140f` | Page and panel backgrounds |
| Primary gold | `#e8a53d` | Buttons, CTAs, active states |
| Secondary gold | `#c8861a` | Borders, icon accents, hover states |
| Parchment text | `#f4e4c1` | Body text on dark backgrounds |
| Muted text | `rgba(244,228,193,0.4–0.6)` | Secondary labels, timestamps |
| Heading fonts | Playfair Display, Space Grotesk | Page headings, landing page |
| Body / editorial font | Lora | Note bodies, prose |
| Verse / italic font | IM Fell English | Verse references, pull quotes |
| Mono font | JetBrains Mono | Code-adjacent UI elements |

---

## Layout Strategy

The web app uses a **three-panel grid** in the Reader view:

```
┌──────────┬────────────────────┬────────────────┐
│  AppNav  │  Scripture text    │  Notes or      │
│  (left)  │  (centre)          │  Messaging     │
│          │                    │  sidebar       │
└──────────┴────────────────────┴────────────────┘
```

On narrow viewports, sidebars collapse to toggle buttons above the scripture view.

The **Home** page is a full-width landing page with a top navigation bar, not an in-app panel. Signed-out users see it as the entry point; signed-in users pass through it to reach `/reader`.

---

## Pages

- [Home Page](home-page.md) — Public landing page with pricing and feature overview
- [Bible Reader](bible-reader.md) — Scripture reading with notes and messaging sidebars
- [Notes](notes.md) — Rich-text notes, highlights, and the note creation date feature
- [Community](community.md) — Real-time group chat, DMs, and friend management
