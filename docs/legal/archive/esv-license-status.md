# ESV text license status (ARCHIVED -- ESV is no longer this app's translation)

**Superseded 2026-09-27 (task `20260927-esv-bible-source-migration`,
revision 2): the app replaced ESV entirely with the public-domain World
English Bible (WEB).** This document is kept, frozen, for historical
record only -- not deleted, matching this repo's existing
archive-don't-silently-delete convention (`api/backend/bibleHandling/archive/convertDict.py`).
It no longer describes this app's actual translation source or licensing
posture. See `docs/legal/bible-translation-source.md` for the current,
short record (WEB/CC0, no license needed). The user's separate, personal
pursuit of a formal Crossway ESV license (Path 1 below) continues
independently of this app and this task -- see that doc for a pointer.

Everything below this line is the original record as it stood before the
WEB switch, preserved verbatim for history.

---

# ESV text license status

**Status as of 2026-09-27: requested, not yet confirmed or on file.**

This file is the durable, in-repo record required by task
`20260927-esv-bible-source-migration`'s acceptance criteria -- it exists so
the pending license state is checkable by any future session or gate
without relying on that task's own pipeline paperwork or conversation
history.

## What this app does with the ESV text

FellowScript's Bible reader is a genuine complete-Bible offline reader (all
66 books, full navigation), not a bounded-quotation feature. It ships the
full ESV text as a static, pre-generated `bible.json` bundled in the iOS app
and mirrored in the backend API (see `docs/architecture/data.md` and
`backend/bibleHandling/generate_bible_data.py`).

## api.esv.org's free-tier terms (Standard Use Guidelines for the ESV)

Confirmed directly against Crossway's own published terms
(`https://api.esv.org/docs/`, `https://api.esv.org/docs/changelog/`,
`https://www.crossway.org/permissions/`) at the time this task was scoped:

- Free/self-serve use permits quoting **up to 500 verses total**, not
  exceeding **50% of any one book**, and not exceeding **25% of the quoting
  work's own total text**, **without a formal license or express written
  permission from Crossway**.
- A single query that exceeds these limits gets its response **truncated**
  by the API itself -- this is enforced per-query, not as a cumulative
  account-level block. It does **not** prevent (and the terms don't excuse)
  reassembling the complete text across many small, individually-compliant
  chapter-by-chapter queries, which is exactly what this app's generation
  pipeline does.
- Anything beyond the free-tier thresholds "require[s] written permission or
  a formal license."

**Full bundled reproduction of the complete ESV -- what this app's offline
reader requires -- exceeds these free-tier terms.** A formal Crossway
digital-reproduction license is required to legally ship it.

## The decision (Path 1)

The user has decided to proceed on **Path 1**: personally submit a formal
Crossway digital-reproduction license request for FellowScript through
Crossway's own online permissions process (`crossway.org/permissions/`) --
an app-level license requested directly by the user, outside this
repo/pipeline's own scope. That request is **in progress but not confirmed**
as of this document's date. There is no license number, grant letter, or
executed agreement on file anywhere in this repository.

## What is and isn't unblocked by this status

- **Unblocked now:** building and testing the api.esv.org-backed technical
  integration and generation pipeline (`backend/bibleHandling/esv_client.py`,
  `backend/bibleHandling/generate_bible_data.py`) -- api.esv.org's own API
  happily serves the individual per-chapter queries this pipeline makes
  (each one is well within the 500-verse-per-query cap), so the pipeline
  itself runs and can be verified independent of the licensing question.
- **Gated on the license landing:** actually shipping/serving the full
  bundled ESV text in production. Running
  `python -m backend.bibleHandling.generate_bible_data` and deploying its
  output is a real-world legal decision the user makes once (or if) the
  formal license is confirmed -- not an automatic next step this pipeline
  should take unprompted.

## Attribution requirement (not yet wired into UI)

Crossway's terms require a copyright/attribution notice on displayed ESV
text (e.g. the short "(ESV)" suffix or a full copyright notice --
`include-short-copyright`/`include-copyright` on api.esv.org's own passage
endpoints). `generate_bible_data.py` deliberately does **not** bake either
into every one of the ~1,189 stored chapter blobs (duplicating it that many
times is unnecessary and would itself need stripping out of the parsed
verse text downstream). Displaying the required attribution once, centrally,
in the iOS reader / web reader UI has **not** been implemented as part of
this task (out of this task's backend scope) -- flagged here as an open
follow-up for whichever team/gate next touches the reader UI.

## History

See task `20260927-esv-bible-source-migration`'s own pipeline artifacts for
the full reasoning trail:
`.claude/pipeline/20260927-esv-bible-source-migration/backend.json` (the
original spec-level bounce that first surfaced this gap, before the spec was
revised with the Path 1 decision above) and `intake-spec.md`.
