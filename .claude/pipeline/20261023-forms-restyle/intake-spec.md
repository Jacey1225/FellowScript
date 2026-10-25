# Intake spec: 20261023-forms-restyle

## Request
Restyle ALL FellowScript form screens (iOS and web/desktop) to SQUIDWARD's revised design spec (Revision 2). Jacey approved the designs. Source: BALJEET hand-off, message 1563291074380824608.
- Spec: /Users/jaceysimpson/.claude/design/20261023-fellowscript-forms-modernization/design-spec.md (read "Revision 2" first). Mockups: .../mockups/png and .../mockups/html.
- Scope: every entry in .claude/pipeline/20261023-forms-design-audit/forms-inventory.md except the 4 legacy ones (F-089..F-092).
- Rules: keep spec layouts and palette; system font (SF Pro) with spec weights, no `.inter()` / `.playfair()` in form views; cards use `Theme.cardGlassGray` + `Theme.borderGray` or `.glassCard`.
- Branch: worktree forms-restyle (base ios-build-2-9-9, build 132). Mind group-info-row merge ordering.
- Limits: no push/deploy without asking Jacey in the FELIX channel. iOS simulator tests one at a time.
- Process: all pipeline steps run inline by the session (no sub-agents) after the prior session froze launching one.

## Summary
Introduce one shared form kit per platform (iOS `FSForm*` on Theme; web `Form*` components + one shared token file feeding antd ConfigProvider and global.css), then migrate each of the 89 in-scope entries (F-001..F-093 minus F-089..F-092) onto it by type A-H with the S (sensitive) modifier. Behavior, validation, autofill attributes, disclaimers and feature flags must be preserved; only presentation, layout, and the spec'd interaction patterns (pinned/sticky action bar, stepper, error card, destructive tiers) change.

## Type
Full (multi-layer: iOS + web, shared components, ~89 entries, token changes).

## Scope
In:
- Shared kits: iOS FSForm* (scaffold, section, field, toggle row, chips, segmented, radio list, number stepper, stepper rail, pinned bar, error card, destructive confirm); web FormShell/Field/etc., sticky footer, tokens (spec 11.1 remap of antd #C8861A and global.css #FFC61A to iOS #D4922A family).
- Migration of types A-H per spec 5.1 for F-001..F-088 and F-093.
- Fonts: system font only in form views; wordmark stays Schibsted.
- Keep existing parity tests green or update them in the same change (GroupInfoParity, SessionWidget.parity, Account.redesign.test.jsx, AnnouncementTitleColorFlow, AnnouncementBannerLayout).
Out:
- F-089..F-092 legacy/dead code.
- Native pickers (photo, file, attachments) stay native.
- Backend/API changes. New features (e.g. web Repeat, parity work) per D29.
- Any push, deploy, TestFlight, or server restart (needs Jacey approval).
- Entries flagged O (overlap with branch group-info-row, NOT merged into base): F-029..F-034, F-037..F-039, F-041..F-048 (shared global.css classes), F-049, F-065, F-067, F-068. They are sequenced LAST and only after group-info-row merges into ios-build-2-9-9 and forms-restyle is rebased on it; until then they are held and reported.

## Acceptance criteria
1. Every in-scope entry renders with spec tokens: gray glass cards (cardGlassGray + borderGray, radius 20), parchment@6% fields with parchment@12% border, no gold card borders, no Playfair/Inter in form views.
2. Pinned bar (iOS) / sticky footer (web) is the single primary action placement; stepper on type A forms; error summary and retry card per 2.9; destructive tiers per 9.2.
3. Sensitive forms keep autofill attributes, textContentType, masked inputs, disclaimers.
4. iOS: project builds, existing tests pass, new tests for kit components; web: vitest suite passes, parity tests pass or are updated.
5. Tests run serially (one xcodebuild at a time).
6. No push/deploy performed. Deferred O entries are listed with the reason.

## Preference profile
From ~/Downloads/ai_preference_survey_tracker.md (UI/UX, Architecture, Security, Configuration complete). Established answers applied by the spec itself: undo-snackbar over blocking confirms for low-impact deletes (D17), plain spinners, warm error copy. Architecture: one shared component set rather than per-screen skins (spec 10); keep changes reversible and small per commit; no speculative abstraction beyond the kit. Security: preserve all autofill/secure-entry attributes (spec 9).

## Open questions
1. Which O entries to build and when (group-info-row not merged). Default: hold them; ask Jacey in channel when the rest is done.
2. Tests parity files assert class names; may need updates per kit.
3. D26 password rule copy follows whatever the API enforces.
4. Web gold shift (#FFC61A to #D4922A) is intentional per D24.
