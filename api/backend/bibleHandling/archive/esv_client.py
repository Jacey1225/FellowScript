"""RETIRED (task 20260927-esv-bible-source-migration, revision 2): the app's
Bible translation was switched from ESV to the public-domain World English
Bible (WEB) before this integration ever shipped -- ``generate_bible_data.py``
now sources from a vendored WEB dataset via ``../web_source.py`` instead
(see ``data/vendor/SOURCE.md`` and ``docs/legal/bible-translation-source.md``).
This module (and the ``ESV_API_KEY``-gated api.esv.org integration it
implemented) is frozen here for history only -- never imported by anything
live. It was built and unit-verified under this same task's revision 1
(see ``.claude/pipeline/20260927-esv-bible-source-migration/backend.json``
for that work's own writeup) while the app's translation was still ESV, but
the user decided to drop ESV entirely -- along with its unresolved Crossway
licensing gap (``docs/legal/archive/esv-license-status.md``) -- before that
integration was ever regenerated into a shipped ``bible.json``. Do not
re-import this module; the whole point of the WEB switch is that no
licensed/rate-limited/credentialed API is needed at all.

Original docstring follows, preserved for history:

Thin client for api.esv.org's ``/v3/passage/text/`` endpoint.

Build-time/generation-time only -- imported by ``generate_bible_data.py``,
never by anything on the live request path (``bible_text.py`` explicitly
stays a static, in-process, no-network lookup; see its own docstring). No
mature third-party ESV API SDK exists on PyPI (checked directly against
pypi.org before writing this -- searches for ``esv-api``/``pyesv``/``esv``
all 404, and a broad "esv bible api" pypi search turned up nothing usable),
so this hand-rolls the HTTP call on top of ``httpx``, which is already this
project's established HTTP client dependency (``backend/interactions/
push.py``, ``backend/interactions/gif_search.py``) -- no new supply-chain
surface added (Security Posture Q9/Q29).

Configuration split (Configuration Philosophy Q2/Q9, same pattern as
``gif_search.py``):
    - ``ESV_API_KEY`` is a secret -- loaded here, at import time, through
      this module's own ``os.getenv`` call, a completely separate path from
      ordinary config. Never logged, never echoed back, never written to an
      example config file (there isn't one for backend secrets in this repo
      -- they all live in the gitignored root ``.env``, same as this one).
    - The base URL and rendering parameters below are NOT deployment-
      specific (api.esv.org's endpoint and this project's rendering choices
      never vary per environment), so they're plain module constants, not
      env vars (Configuration Philosophy Q2 -- env vars are reserved for
      values that actually vary per deployment).
"""

from __future__ import annotations

import logging
import os
import time

import httpx

logger = logging.getLogger(__name__)

_BASE_URL = "https://api.esv.org/v3/passage/text/"

# Secret: loaded via its own os.getenv call, deliberately never logged or
# echoed back to a caller (Configuration Philosophy Q9). No default -- an
# unset key must fail loudly (validate_esv_config), never silently query
# unauthenticated and get a 401 deep inside a 1,189-chapter generation run.
_ESV_API_KEY = os.getenv("ESV_API_KEY", "")

# Fixed rendering parameters (Configuration Philosophy Q2: these are this
# pipeline's own tunables, not per-deployment values, so they live here as a
# plain dict, not env vars):
#   - include-footnotes=false: footnote callouts/bodies are never displayed
#     by any of the four existing consumers (bible_text.py's docstring
#     documents the legacy `\[\d+\]` marker as something consumers already
#     strip and discard) -- excluding them at the source removes a whole
#     class of transform risk (whatever ESV's own footnote-callout glyph
#     turns out to be, it can never collide with our own constructed verse
#     markers) for content nothing ever shows anyway.
#   - include-verse-numbers / include-first-verse-numbers=true: verse
#     boundaries render as bracketed "[N]" per ESV's own documented example
#     response (`"[35] Jesus wept."`) -- this is what
#     `generate_bible_data._split_verses` parses on.
#   - include-headings=true: section headings (task needs `HEAD::`-style
#     markers preserved, matching the existing data shape).
#   - include-passage-references=false / include-short-copyright=false /
#     include-copyright=false: no reference line or copyright suffix baked
#     into the stored per-chapter text -- attribution is handled once,
#     centrally, not duplicated into every one of 1,189 chapter blobs (see
#     docs/legal/esv-license-status.md for the attribution requirement
#     itself).
#   - indent-poetry=false / line-length=0: no line-wrapping or poetry
#     indentation whitespace to normalize back out before this pipeline's
#     verse-splitting regex runs.
_RENDER_PARAMS = {
    "include-passage-references": "false",
    "include-verse-numbers": "true",
    "include-first-verse-numbers": "true",
    "include-footnotes": "false",
    "include-footnote-body": "false",
    "include-headings": "true",
    "include-short-copyright": "false",
    "include-copyright": "false",
    "include-selahs": "true",
    "include-passage-horizontal-lines": "false",
    "include-heading-horizontal-lines": "false",
    "indent-poetry": "false",
    "indent-paragraphs": "0",
    "line-length": "0",
}

_MAX_ATTEMPTS = 3
_RETRY_BACKOFF_SECONDS = 1.5
_REQUEST_TIMEOUT_SECONDS = 20.0


class ESVConfigError(RuntimeError):
    """api.esv.org integration is not configured (missing ``ESV_API_KEY``).

    Mirrors ``push.py``'s ``APNsConfigError`` / ``gif_search.py``'s
    ``GifConfigError`` precedent -- named exactly what's missing, never the
    key value itself.
    """


class ESVFetchError(RuntimeError):
    """A single api.esv.org request failed (non-2xx after retries, a
    network error, or a 200 response missing the expected ``passages``
    field). Distinct from ``ESVConfigError`` so the generation script can
    tell "not configured at all" apart from "the service/one query failed
    right now."""


def validate_esv_config() -> None:
    """Eagerly validate api.esv.org config before a generation run starts.

    Raises ``ESVConfigError`` naming exactly what's missing. Call this
    before the first of ~1,189 per-chapter requests, not after discovering
    the first 401 partway through a run.
    """
    if not _ESV_API_KEY:
        raise ESVConfigError(
            "api.esv.org is not configured: missing ESV_API_KEY. Set it "
            "explicitly (see docs/legal/esv-license-status.md for the "
            "account/terms this key is subject to) -- there is no implicit "
            "default or fallback source."
        )


def fetch_chapter_passage(book: str, chapter: int) -> dict:
    """Fetch one whole chapter's plain text from api.esv.org.

    ``book``/``chapter`` are combined into a single ``"{book} {chapter}"``
    query (e.g. ``"John 3"``) -- api.esv.org resolves this to the full
    chapter (see its docs: ``q=Genesis 1-3`` style ranges are supported, and
    a bare ``q=Isaiah 40`` resolves to that whole chapter). Returns the
    parsed JSON response dict; callers read ``response["passages"][0]`` for
    the chapter's own text and ``response["passage_meta"][0]`` for
    validation (``chapter_start``/``next_chapter`` etc.).

    Raises:
        ESVConfigError: if ``ESV_API_KEY`` is unset (call
            ``validate_esv_config()`` up front instead of relying on this).
        ESVFetchError: on a non-2xx response (after retries), a network
            failure, or a 200 response that doesn't contain a usable
            ``passages`` entry.
    """
    if not _ESV_API_KEY:
        raise ESVConfigError("ESV_API_KEY is not set -- call validate_esv_config() first.")

    query = f"{book} {chapter}"
    params = {"q": query, **_RENDER_PARAMS}
    headers = {"Authorization": f"Token {_ESV_API_KEY}"}

    last_error: Exception | None = None
    for attempt in range(1, _MAX_ATTEMPTS + 1):
        try:
            with httpx.Client(timeout=_REQUEST_TIMEOUT_SECONDS) as client:
                resp = client.get(_BASE_URL, params=params, headers=headers)
        except httpx.HTTPError as e:
            last_error = e
            logger.warning("api.esv.org request failed for %r (attempt %d/%d): %s",
                            query, attempt, _MAX_ATTEMPTS, e)
            if attempt < _MAX_ATTEMPTS:
                time.sleep(_RETRY_BACKOFF_SECONDS * attempt)
            continue

        if resp.status_code == 401 or resp.status_code == 403:
            # Never retry an auth failure -- retrying won't fix a bad/
            # revoked key, and hammering the endpoint with a rejected
            # credential is exactly the kind of thing a supply-chain-aware
            # integration should avoid.
            raise ESVFetchError(
                f"api.esv.org rejected the request for {query!r} "
                f"(HTTP {resp.status_code}) -- check ESV_API_KEY."
            )
        if resp.status_code >= 500:
            last_error = ESVFetchError(f"api.esv.org returned HTTP {resp.status_code} for {query!r}")
            logger.warning("api.esv.org server error for %r (attempt %d/%d): HTTP %d",
                            query, attempt, _MAX_ATTEMPTS, resp.status_code)
            if attempt < _MAX_ATTEMPTS:
                time.sleep(_RETRY_BACKOFF_SECONDS * attempt)
            continue
        if resp.status_code != 200:
            raise ESVFetchError(
                f"api.esv.org returned unexpected HTTP {resp.status_code} for {query!r}: "
                f"{resp.text[:300]!r}"
            )

        try:
            data = resp.json()
        except ValueError as e:
            raise ESVFetchError(f"api.esv.org returned non-JSON for {query!r}: {e}") from e

        passages = data.get("passages")
        if not passages or not isinstance(passages, list) or not passages[0].strip():
            raise ESVFetchError(
                f"api.esv.org returned no passage text for {query!r} -- "
                f"chapter likely out of range for this book. Response: {data!r}"
            )
        return data

    raise ESVFetchError(
        f"api.esv.org request for {query!r} failed after {_MAX_ATTEMPTS} attempts: {last_error}"
    )
