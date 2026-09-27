# Vendored source: World English Bible (WEB), USFX format

Task `20260927-esv-bible-source-migration`.

`eng-web.usfx.xml` is a **pinned, one-time snapshot** of the World English
Bible in USFX XML format, vendored directly into this repo rather than
fetched at build time or request time -- this is a static, essentially
never-changing public-domain text, not a live feed, so there is nothing to
keep in sync with on an ongoing basis (Architecture/Implementation Q29 --
the simplest reliable option for a one-time static-dataset pull needs no new
runtime dependency, no credential, and no recurring-sync machinery).

## Provenance

- **Upstream repo:** [`seven1m/open-bibles`](https://github.com/seven1m/open-bibles)
  -- the data submodule behind [`seven1m/bible_api`](https://github.com/seven1m/bible_api)
  (the open-source project that runs bible-api.com).
- **File:** `eng-web.usfx.xml`
- **Pinned commit:** [`f257a3559025c3f873b48a75019f53a9354ed7de`](https://github.com/seven1m/open-bibles/blob/f257a3559025c3f873b48a75019f53a9354ed7de/eng-web.usfx.xml)
  (2026-07-21)
- **Pulled:** 2026-09-27, via a direct one-time `curl` of that commit's raw
  file content -- confirmed byte-identical to what `seven1m/open-bibles`
  itself serves at that pinned commit, not re-derived or re-typed.
- **SHA-256 of the vendored file:** `5ffa2626f170a109a4a96afc90775c06f0821cb4ba81ed34e63663e085708d68`

## License

**Public Domain.** `seven1m/open-bibles`'s own translation table lists
`eng-web.usfx.xml` / World English Bible as `Public Domain`, and
`bible-api.com`'s own documented example response tags every WEB verse
`"translation_note": "Public Domain"`. No quotation cap, no "organizations
only" clause, no attribution requirement, nothing to request permission
for -- unlike the retired ESV/api.esv.org path (see
`docs/legal/archive/esv-license-status.md`), there is no ongoing legal-risk
surface here to track. See `docs/legal/bible-translation-source.md` for the
short in-repo record of this decision.

## Why vendored instead of fetched live

- `open-bibles` is a slow-changing reference dataset (translation text
  doesn't change), not a live feed -- pinning a specific commit's file
  gives fully reproducible builds with **no runtime network dependency**,
  matching this project's existing preference for a static, no-live-fetch
  reference asset (`docs/architecture/data.md`'s existing framing:
  "a DB table or an outbound third-party API call would be real added
  maintenance/failure-mode surface for content that never changes at
  runtime").
- No API key, no rate limit, no live-service outage risk -- unlike the
  superseded api.esv.org integration this replaces.

## How it's used

`api/backend/bibleHandling/web_source.py` parses this file (via
`defusedxml`, external-entity resolution disabled as ordinary secure
practice for parsing a vendored-but-externally-sourced XML document) and
`api/backend/bibleHandling/generate_bible_data.py` walks it one real
`(book, chapter)` at a time to produce `data/bible.json`. See that module's
own docstring for the extraction algorithm and how it avoids reproducing
the orphan-array-entry / missing-placeholder / heading-swallowing bug
classes found in the retired ESV pipeline.

## Updating this snapshot

There is no expectation this needs to change -- WEB's text is finished and
stable. If `seven1m/open-bibles` ever republishes a corrected `eng-web.usfx.xml`
worth picking up, re-pull the file from a specific commit (never `master`
unpinned, to keep builds reproducible), update the pinned commit SHA and
file SHA-256 above, and re-run
`python -m backend.bibleHandling.generate_bible_data`.
