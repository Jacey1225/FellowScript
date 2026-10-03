"""Validated tunables for Explorer listing media (``api/config/explorer.json``,
section ``media``).

Same rules as ``listings_config``: every key required through the shared
``config_loader`` (no implicit defaults, unknown keys and wrong types
rejected), cached after the first successful load, validated at startup so a
bad file refuses to boot. ``video_enabled`` is false by default: the video
path is inert until it is flipped by hand.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from limits import parse as _parse_rate

from backend.config_loader import ConfigSectionError, load_section

CONFIG_PATH = Path(__file__).resolve().parents[2] / "config" / "explorer.json"
SECTION = "media"

# MIME -> (stored extension, Pillow format). Reference data, not a tunable: the
# set of formats this module can decode and re-encode. HEIC, GIF, SVG and AVIF
# are deliberately absent.
SUPPORTED_MIME = {
    "image/jpeg": (".jpg", "JPEG"),
    "image/png": (".png", "PNG"),
    "image/webp": (".webp", "WEBP"),
}
RATE_LIMIT_KEYS = ("upload_url_user", "upload_url_ip", "confirm", "manage")
_PROVIDER_RE = re.compile(r"^[a-z]{3,20}$")
SUPPORTED_PROVIDERS = frozenset({"youtube", "vimeo"})

_INT_KEYS = (
    "image_max_upload_mb", "image_min_upload_bytes", "max_pixels", "max_side_px",
    "output_max_side_px", "jpeg_quality", "webp_quality", "max_images_per_listing",
    "max_bytes_per_listing", "alt_max_length", "upload_url_ttl_seconds",
    "download_url_ttl_seconds", "download_url_cache_seconds", "confirm_concurrency",
    "confirm_wait_seconds", "orphan_grace_hours", "sweep_interval_minutes",
    "sweep_max_keys_per_run",
)
_REQUIRED = _INT_KEYS + ("video_enabled", "video_providers", "allowed_mime", "rate_limits")
_TYPES = {k: int for k in _INT_KEYS}
_TYPES.update({"video_enabled": bool, "video_providers": list, "allowed_mime": list, "rate_limits": dict})

# Hard ceilings: a config value above these would defeat the memory budget
# (a decoded 36 MP RGB image is about 108 MB against a 1500 MB container).
_MAX_PIXELS_CEILING = 36_000_000
_MAX_SIDE_CEILING = 6000
_MAX_UPLOAD_MB_CEILING = 20
_MAX_CONCURRENCY_CEILING = 4


@dataclass(frozen=True)
class MediaConfig:
    video_enabled: bool
    video_providers: tuple
    allowed_mime: tuple
    image_max_upload_mb: int
    image_min_upload_bytes: int
    max_pixels: int
    max_side_px: int
    output_max_side_px: int
    jpeg_quality: int
    webp_quality: int
    max_images_per_listing: int
    max_bytes_per_listing: int
    alt_max_length: int
    upload_url_ttl_seconds: int
    download_url_ttl_seconds: int
    download_url_cache_seconds: int
    confirm_concurrency: int
    confirm_wait_seconds: int
    orphan_grace_hours: int
    sweep_interval_minutes: int
    sweep_max_keys_per_run: int
    rate_limits: dict

    @property
    def max_upload_bytes(self) -> int:
        return self.image_max_upload_mb * 1024 * 1024

    @property
    def max_description_images(self) -> int:
        """One photo and one banner come out of the per-listing image budget."""
        return max(self.max_images_per_listing - 2, 0)


_cached: MediaConfig | None = None


def _err(msg: str) -> ConfigSectionError:
    return ConfigSectionError(f"explorer.json[{SECTION}]: {msg}")


def _load() -> MediaConfig:
    raw = load_section(CONFIG_PATH, SECTION, required_keys=_REQUIRED, types=_TYPES)
    for key in _INT_KEYS:
        if raw[key] < 1:
            raise _err(f"{key} must be >= 1")
    if raw["max_pixels"] > _MAX_PIXELS_CEILING:
        raise _err(f"max_pixels cannot exceed {_MAX_PIXELS_CEILING} (container memory)")
    if raw["max_side_px"] > _MAX_SIDE_CEILING:
        raise _err(f"max_side_px cannot exceed {_MAX_SIDE_CEILING}")
    if raw["image_max_upload_mb"] > _MAX_UPLOAD_MB_CEILING:
        raise _err(f"image_max_upload_mb cannot exceed {_MAX_UPLOAD_MB_CEILING}")
    if raw["confirm_concurrency"] > _MAX_CONCURRENCY_CEILING:
        raise _err(f"confirm_concurrency cannot exceed {_MAX_CONCURRENCY_CEILING}")
    if raw["output_max_side_px"] > raw["max_side_px"]:
        raise _err("output_max_side_px must not exceed max_side_px")
    for key in ("jpeg_quality", "webp_quality"):
        if not 1 <= raw[key] <= 100:
            raise _err(f"{key} must be between 1 and 100")
    if raw["max_images_per_listing"] < 3:
        raise _err("max_images_per_listing must be at least 3 (photo, banner and one description image)")
    if raw["download_url_cache_seconds"] >= raw["download_url_ttl_seconds"]:
        raise _err("download_url_cache_seconds must be shorter than download_url_ttl_seconds")
    if raw["image_min_upload_bytes"] >= raw["image_max_upload_mb"] * 1024 * 1024:
        raise _err("image_min_upload_bytes must be below the maximum upload size")

    mimes = raw["allowed_mime"]
    if not mimes or any(not isinstance(m, str) or m not in SUPPORTED_MIME for m in mimes) or len(set(mimes)) != len(mimes):
        raise _err(f"allowed_mime must be a non-empty subset of {sorted(SUPPORTED_MIME)}")
    providers = raw["video_providers"]
    if (
        not providers
        or any(not isinstance(p, str) or not _PROVIDER_RE.fullmatch(p) or p not in SUPPORTED_PROVIDERS for p in providers)
        or len(set(providers)) != len(providers)
    ):
        raise _err(f"video_providers must be a non-empty subset of {sorted(SUPPORTED_PROVIDERS)}")

    rates = raw["rate_limits"]
    if set(rates) != set(RATE_LIMIT_KEYS):
        raise _err(f"rate_limits must contain exactly {list(RATE_LIMIT_KEYS)}")
    for key, value in rates.items():
        try:
            if not isinstance(value, str):
                raise ValueError("not a string")
            _parse_rate(value)
        except Exception as e:  # noqa: BLE001
            raise _err(f"rate_limits.{key} is not a valid rate limit: {e}") from None

    return MediaConfig(
        video_enabled=raw["video_enabled"],
        video_providers=tuple(providers),
        allowed_mime=tuple(mimes),
        rate_limits=dict(rates),
        **{k: raw[k] for k in _INT_KEYS},
    )


def get_media_config() -> MediaConfig:
    """Validated config, loaded once. Raises ``ConfigSectionError``; never defaults."""
    global _cached
    if _cached is None:
        _cached = _load()
    return _cached


def validate_media_config() -> None:
    """Startup check: load uncached so a bad file refuses to boot."""
    global _cached
    _cached = _load()


def reset_for_tests() -> None:
    global _cached
    _cached = None
