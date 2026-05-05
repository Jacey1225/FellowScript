# Bible Reader

The Bible Reader is the core screen of FellowScript. It combines scripture reading, annotation, and community into a single unified interface.

---

## Layout

```
┌────────────────────────────┐
│ < Home   FellowScript  [⋮] │  ← Top nav
├────────────────────────────┤
│ [Search book / chapter   ] │  ← Book/chapter search bar
│ 2 Timothy 1                │  ← Current book & chapter label
│ Highlight: 🟡 🟠 🟢 🔴 🔵  │  ← Highlight color palette
├────────────────────────────┤
│                            │
│  2 Timothy                 │
│  CHAPTER 1                 │
│                            │
│  1 Paul, an apostle of     │
│  Christ Jesus by the will  │  ← Scripture text (Lora, readable size)
│  of God...                 │
│                            │
│  3 [highlighted in gold]   │  ← Community/personal highlights shown inline
│  I thank God, whom I serve │
│  with a clear conscience...│
│                            │
│  7 | For the Spirit God    │  ← Verse 7 shown with teal highlight (community)
│  gave us does not make us  │
│  timid...                  │
│                            │
└────────────────────────────┘
│  [📖 Read] [📝 Notes] [👥 Community] │  ← Bottom tab bar
└────────────────────────────┘
```

---

## Features

### Search Bar
- Sits at the top of the reader
- Opens a **book picker** listing all 66 books
- Selecting a book shows chapter numbers below
- Selecting a chapter loads that passage

### Highlight Palette
- Five colors: yellow, orange, green, pink, blue
- Tap a verse to apply the active color
- Highlights persist per user

### Community Highlights
- A toggle/filter to show other users' public highlights inline
- Each community highlight has a subtle color outline and the user's initials

### Scripture Text
- Clean, well-spaced serif text (Lora)
- Verse numbers displayed inline
- Book title and chapter heading displayed prominently

---

## Bottom Tab Bar

| Tab | Contents |
|---|---|
| Read | Scripture text (default) |
| Notes | All annotations for the current chapter — see [Notes](notes.md) |
| Community | Study group members and group chat — see [Community](community.md) |

---

## Navigation
- **← Home** in the top bar returns to the [Home Page](home-page.md)
- Book/chapter changes stay within this screen
