# Design notes: kit API (step 1)
Source of truth: design-spec.md (Revision 2) in ~/.claude/design/20261023-fellowscript-forms-modernization/. Palette and layouts unchanged; fonts = system; boxes = gray glass.

## iOS kit (FellowScript/FellowScript/Shared/Forms/FSForm*.swift, Theme tokens only)
- Theme additions (Theme.swift): fieldFill (parchment@6%), fieldBorder (parchment@12%), errorStrong (= error), plus font helper `Font.fsForm(size, weight)` = `.system`.
- FSFormCard: gray glass card (cardGlassGray + borderGray, radius 20, pad 16), optional eyebrow/title/trailing action.
- FSField: label (14 semibold, gold asterisk if required, "(optional)"), text/secure/multiline, helper/error slot, counter at >=80%, states default/focus/error/disabled/saving, 48pt, radius 12, optional leading icon and trailing reveal/clear.
- FSToggleRow, FSChipRow (single/multi, check glyph), FSSegmented, FSRadioList, FSNumberStepper, FSStepperRail (+ page logic helper), FSPinnedActionBar (secondary + primary, dimmed-but-tappable primary, saving spinner, tight variant), FSFormErrorCard (summary / retry / info), FSFormScaffold (nav bar with X, optional rail, scroll, error card, pinned bar, discard guard), FSDestructiveConfirm helpers (tier 1 undo snackbar, tier 2 confirmationDialog, tier 3 typed confirm).
- Existing ChipToggle, DateTimeTile, PillButton stay for the held O entries until batch C.

## Web kit (frontend/src/components/forms/*.jsx + styles/forms.css)
- tokens.css (shared): gold #D4922A family, --card-bg gray glass, --field-bg/--field-border, --nav-bg, --danger-bg, --error, text roles; antd theme.js reads the same constants via frontend/src/lib/formTokens.js.
- FormShell (modal/drawer/page containers, sticky footer), FormCard, Field (label for=, aria-invalid/describedby, counter), ToggleRow (role=switch), ChipGroup, Segmented, RadioList, NumberStepper, StepperRail (ol, aria-current=step), StickyActionBar (aria-disabled primary), FormErrorCard (role=alert), ConfirmDialog.
- Fonts: system stack in forms.css; no Lora/Inter in form components.
- Parity tests assert class names (group-info-*, ann-*): untouched until batch C.

## Parity-test impact
Batches A and B do not touch group-info-*/ann-* classes or GroupInfoPanel. Account.redesign.test.jsx will need updates in batch A (Account.jsx is migrated).
