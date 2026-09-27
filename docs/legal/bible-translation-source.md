# Bible translation source

**Current translation: World English Bible (WEB). Public domain (CC0-equivalent). No license required.**

## What this app does with the WEB text

FellowScript's Bible reader is a genuine complete-Bible offline reader (all
66 books, full navigation), not a bounded-quotation feature. It ships the
full WEB text as a static, pre-generated `bible.json` bundled in the iOS app
and mirrored in the backend API (see `docs/architecture/data.md` and
`api/backend/bibleHandling/generate_bible_data.py`).

## Why this is a settled non-issue, not an open tracker

Unlike the retired ESV path this replaces (see
`docs/legal/archive/esv-license-status.md`), WEB carries:

- **No quotation cap.** Free/self-serve ESV use was limited to 500 verses
  total and 50% of any one book without a formal license -- a hard blocker
  for a complete offline Bible reader. WEB has no such limit at any scale --
  bundling the whole translation in full is exactly what it's meant for.
- **No "with permission" clause, no organizations-only restriction, nothing
  to request.** The World English Bible was deliberately created to be
  unencumbered -- see its own preface (vendored in
  `data/vendor/eng-web.usfx.xml`'s `FRT` book): "Because the World English
  Bible is in the Public Domain (not copyrighted), it can be freely copied,
  distributed, and redistributed without any payment of royalties. You
  don't even have to ask permission to do so."
- **No attribution requirement.** ESV's terms required a copyright/
  attribution notice on displayed text; WEB has no such condition. (This
  app doesn't currently display an in-UI translation credit either way --
  nothing is gated on adding one.)
- **Source:** [`seven1m/open-bibles`](https://github.com/seven1m/open-bibles)'s
  `eng-web.usfx.xml`, the same public-domain dataset that backs
  [bible-api.com](https://bible-api.com/) (`seven1m/bible_api`), which tags
  every WEB verse `"translation_note": "Public Domain"` in its own
  documented example response. See `data/vendor/SOURCE.md` for the exact
  pinned commit, checksum, and pull date.

There is nothing here that needs periodic re-checking, unlike
`esv-license-status.md`'s open "pending" state -- this is why this document
is a short factual note rather than an ongoing tracker.

## The user's separate Crossway pursuit

The user is still personally, independently pursuing a formal Crossway ESV
digital-reproduction license as an unrelated business matter, through
Crossway's own permissions process -- entirely outside this app and this
task. It is not tracked here, is not a blocker on anything in this repo,
and is not this task's concern (see
`.claude/pipeline/20260927-esv-bible-source-migration/intake-spec.md` for
that decision). If that pursuit ever succeeds and the user wants to
(re-)add ESV as an additional or alternate translation, that would be a
new, separate future task -- not a resumption of the archived
`esv_client.py`/`esv-license-status.md` work as-is, since this app has since
moved to a structurally different (vendored, no-live-API) generation
pipeline shape.

## History

See task `20260927-esv-bible-source-migration`'s own pipeline artifacts:
`.claude/pipeline/20260927-esv-bible-source-migration/intake-spec.md` (the
revision-2 decision to drop ESV/api.esv.org entirely in favor of WEB) and
`.claude/pipeline/20260927-esv-bible-source-migration/backend.json`.
