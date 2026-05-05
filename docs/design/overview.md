# Design Overview

FellowScript's UI is designed mobile-first with a dark, editorial aesthetic that feels reverent without being heavy.

---

## Visual Identity

| Element | Value |
|---|---|
| Background | Dark charcoal (`#1a1a2e` / near-black) |
| Primary accent | Warm gold (`#C9A84C`) |
| Heading font | Playfair Display (serif) |
| Body font | Lora (serif) |
| Code font | Roboto Mono |

The gold accent on dark creates the parchment-and-candlelight feel of handwritten scripture — modern but grounded.

---

## Layout Strategy

On mobile, traditional sidebars are replaced entirely with a **bottom navigation bar**:

```
[ Read ]  [ Notes ]  [ Community ]
```

This keeps all core actions reachable with one thumb and avoids cluttered side panels on small screens.

---

## Pages

- [Home Page](home-page.md) — Landing, mission, and entry point
- [Bible Reader](bible-reader.md) — Scripture view with highlighting
- [Notes](notes.md) — Public and private annotations
- [Community](community.md) — Study group members and chat
