"""Server-side GIF search proxy (GIPHY / Tenor), provider-agnostic.

Settles the intake spec's open question: GIF search is proxied through the
backend, not called directly from clients with a client-side key -- a
client-side key can't be kept both scoped and secret (Security Posture
Q2/Q6). Only the fields the composer actually needs are ever returned
(``id``, ``url``, ``preview_url``, ``width``, ``height``) -- never the
provider's raw response verbatim, so no provider-side tracking parameters
are ever forwarded to the client.

Configuration split (Configuration Philosophy Q2/Q9):
    - GIF_PROVIDER / GIF_PROVIDER_BASE_URL are deployment-specific (which
      vendor, and an optional non-default base URL) -- env vars.
    - GIF_PROVIDER_API_KEY is a secret. It is loaded here, at import time,
      through this module's own ``os.getenv`` call -- a completely separate
      path from any ordinary config -- and is never logged, never returned
      to a client, and never appears in an example config file.
    - GIF_SEARCH_RESULT_LIMIT is an application-behavior tunable (how many
      results to request per search), not a secret or per-deploy value --
      matching ``backend/interactions/attachments.py``'s precedent, it's a
      plain module constant rather than an env var.

Callers should call the async ``search_gifs`` behind the same per-user
rate limit the route applies (backend/rate_limiting.py's ``limiter``), so
one account can't burn the shared provider quota/cost for every user.
"""

import logging
import os

import httpx

logger = logging.getLogger(__name__)

# ── Deployment-specific config (env vars) ───────────────────────────────────
GIF_PROVIDER = os.getenv("GIF_PROVIDER", "").strip().lower()
# Secret: loaded via its own os.getenv call, deliberately never logged or
# echoed back to a caller (Configuration Philosophy Q9).
_GIF_PROVIDER_API_KEY = os.getenv("GIF_PROVIDER_API_KEY", "")
_GIF_PROVIDER_BASE_URL_OVERRIDE = os.getenv("GIF_PROVIDER_BASE_URL", "")

_DEFAULT_BASE_URLS = {
    "giphy": "https://api.giphy.com/v1/gifs",
    "tenor": "https://tenor.googleapis.com/v2",
}

# ── Application-behavior tunable ─────────────────────────────────────────────
GIF_SEARCH_RESULT_LIMIT = 24


class GifConfigError(RuntimeError):
    """GIF search is unconfigured (missing/unrecognized GIF_PROVIDER, or no
    GIF_PROVIDER_API_KEY). Mirrors ``attachments.py``'s
    ``AttachmentConfigError``/``push.py``'s ``APNsConfigError`` precedent --
    surfaced loudly at startup via ``validate_gif_config`` (called from
    main.py's lifespan), and caught specifically by the route to return a
    clear 503 rather than a generic 500 on an individual search.
    """


class GifSearchError(RuntimeError):
    """The configured GIF provider's API call itself failed (network error,
    non-2xx response, or an unrecognized response shape) -- distinct from
    ``GifConfigError`` so the route can tell "not configured" (503) apart
    from "provider is down/erroring right now" (502).
    """


def _missing_config_vars() -> list[str]:
    missing = []
    if GIF_PROVIDER not in _DEFAULT_BASE_URLS:
        missing.append("GIF_PROVIDER (must be 'giphy' or 'tenor')")
    if not _GIF_PROVIDER_API_KEY:
        missing.append("GIF_PROVIDER_API_KEY")
    return missing


def validate_gif_config() -> None:
    """Eagerly validate GIF search config at startup.

    Raises ``GifConfigError`` naming exactly what's missing/wrong -- never
    the key value itself.
    """
    missing = _missing_config_vars()
    if missing:
        raise GifConfigError(
            "GIF search is not configured: missing/invalid "
            f"{', '.join(missing)}. Set them explicitly -- there is no "
            "implicit default GIF provider."
        )


def _base_url() -> str:
    return _GIF_PROVIDER_BASE_URL_OVERRIDE or _DEFAULT_BASE_URLS.get(GIF_PROVIDER, "")


def _shape_giphy(raw: list[dict]) -> list[dict]:
    results = []
    for item in raw:
        images = item.get("images", {}) or {}
        original = images.get("original", {}) or {}
        preview = images.get("fixed_width_small", {}) or images.get("fixed_width", {}) or {}
        results.append({
            "id": item.get("id", ""),
            "url": original.get("url", ""),
            "preview_url": preview.get("url", "") or original.get("url", ""),
            "width": int(original.get("width") or 0),
            "height": int(original.get("height") or 0),
        })
    return results


def _shape_tenor(raw: list[dict]) -> list[dict]:
    results = []
    for item in raw:
        formats = item.get("media_formats", {}) or {}
        gif = formats.get("gif", {}) or {}
        tiny = formats.get("tinygif", {}) or {}
        dims = gif.get("dims") or [0, 0]
        results.append({
            "id": item.get("id", ""),
            "url": gif.get("url", ""),
            "preview_url": tiny.get("url", "") or gif.get("url", ""),
            "width": int(dims[0]) if len(dims) > 0 else 0,
            "height": int(dims[1]) if len(dims) > 1 else 0,
        })
    return results


async def search_gifs(query: str) -> list[dict]:
    """Search the configured GIF provider; return only composer-relevant fields.

    Returns an empty list for a blank query (no round trip needed).

    Raises:
        GifConfigError: If GIF search isn't configured.
        GifSearchError: If the provider call fails (network error, non-2xx,
            or an unrecognized response shape).
    """
    validate_gif_config()
    query = (query or "").strip()
    if not query:
        return []

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            if GIF_PROVIDER == "giphy":
                resp = await client.get(f"{_base_url()}/search", params={
                    "api_key": _GIF_PROVIDER_API_KEY,
                    "q": query,
                    "limit": GIF_SEARCH_RESULT_LIMIT,
                })
                resp.raise_for_status()
                return _shape_giphy(resp.json().get("data", []) or [])

            # validate_gif_config() already confirmed GIF_PROVIDER is one of
            # the two recognized values, so this is the only remaining branch.
            resp = await client.get(f"{_base_url()}/search", params={
                "key": _GIF_PROVIDER_API_KEY,
                "q": query,
                "limit": GIF_SEARCH_RESULT_LIMIT,
                "media_filter": "gif",
            })
            resp.raise_for_status()
            return _shape_tenor(resp.json().get("results", []) or [])
    except GifSearchError:
        raise
    except Exception as e:
        logger.warning("GIF search against %s failed: %s", GIF_PROVIDER, e)
        raise GifSearchError(f"GIF provider request failed: {e}") from e
