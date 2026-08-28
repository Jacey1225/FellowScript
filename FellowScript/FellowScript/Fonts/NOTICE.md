# Bundled font licenses

Fonts bundled in this directory for the "Ember Glass" visual system
(task `20260827-ember-glass-chat-rewrite`), replacing the previous
`Font.playfair()`/`Font.lora()` builders that silently resolved to system
fonts (SF Pro Rounded / New York) despite their names.

## Playfair Display

- Files: `PlayfairDisplay-Regular.ttf`, `PlayfairDisplay-SemiBold.ttf`,
  `PlayfairDisplay-Bold.ttf`, `PlayfairDisplay-Italic.ttf`
- Source: Google Fonts (`google/fonts` repo, `ofl/playfairdisplay`), converted
  from the published variable font to static per-weight instances via the
  legacy Google Fonts CSS v1 API (same upstream font data, static-instance
  delivery — needed because SwiftUI's `Font.custom(name:size:)` looks up a
  font by a single PostScript name and does not resolve variable-font weight
  axes on its own).
- License: **SIL Open Font License, Version 1.1** (full text: `OFL-PlayfairDisplay.txt`
  in this directory, fetched directly from `google/fonts` and verified to be
  OFL 1.1, matching the project's expected-outcome check from the design gate).
- OFL 1.1 permits bundling/embedding in a closed-source commercial app at no
  royalty; the only obligations are (a) this license text ships alongside the
  font files (see `OFL-PlayfairDisplay.txt`) and (b) the font name is not used
  to imply endorsement of the app by the Playfair Display Project Authors.
  Both are satisfied: the license file is bundled here and the app does not
  claim any endorsement.
- PostScript names actually used by `Theme.swift`'s `Font.playfair()` /
  `Font.verseRef()` builders: `PlayfairDisplay-Regular`, `PlayfairDisplay-SemiBold`,
  `PlayfairDisplay-Bold`, `PlayfairDisplay-Italic` (verified against each file's
  `name` table — matches the filename in every case).

## Inter

- Files: `Inter-Regular.ttf`, `Inter-SemiBold.ttf`, `Inter-Bold.ttf`
- Source: Google Fonts (`google/fonts` repo, `ofl/inter`), same static-instance
  delivery method as above.
- License: **SIL Open Font License, Version 1.1** (full text: `OFL-Inter.txt` in
  this directory). Same permissions/obligations as Playfair Display above —
  bundling is permitted, license text is bundled, no endorsement is implied.
- PostScript names actually used by `Theme.swift`'s `Font.inter()` builder
  (introduced this task, replacing the retired `Font.lora()`, which rendered
  system New York despite its name): `Inter-Regular`, `Inter-SemiBold`, `Inter-Bold`.

## Verification method

Each `.ttf` file's internal `name` table was inspected directly (via
`fonttools`) to confirm its PostScript name (table entry 6) matches what
`Theme.swift` registers in `Font.playfair()`/`Font.inter()`/`Font.verseRef()`,
and each family's `OFL.txt` was fetched from the same `google/fonts` commit
that serves the font files themselves, not assumed from general knowledge of
Google Fonts' typical licensing. This satisfies the intake spec's requirement
for "a documented license check ... recorded somewhere durable" (open question 6).
