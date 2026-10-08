"""Validated tunables for the creator Affiliates page
(``api/config/affiliates.json``, section ``affiliates``; task 20261007-affiliates-page).

Loaded through the shared ``config_loader`` (every key required, unknown keys
and wrong types rejected, no implicit defaults), cached after first load.
``validate_affiliates_config()`` runs from ``startup_checks``. The feature flag
itself is the DB flag ``affiliates`` (default off, see ``flags.py``).

Resources: ``file`` is the source path under the repo ``data/`` directory; the
running API serves a copy from ``api/assets/affiliates/<key><ext>`` (the Docker
image contains only ``api/``, never ``data/``). ``scripts/sync_affiliate_assets.py``
makes the copies.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from limits import parse as _parse_rate

from backend.config_loader import ConfigSectionError, load_section

CONFIG_PATH = Path(__file__).resolve().parents[2] / "config" / "affiliates.json"
ASSETS_DIR = Path(__file__).resolve().parents[2] / "assets" / "affiliates"
SECTION = "affiliates"
SERIES_UNITS = ("day", "week", "month")
RESOURCE_SECTIONS = ("logos", "guides", "ads", "qr")
CONTENT_TYPES = {
    "image/png": ".png", "image/jpeg": ".jpg", "image/svg+xml": ".svg", "application/pdf": ".pdf",
}
_KEY_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")


@dataclass(frozen=True)
class Milestone:
    subscribers: int
    bonus_cents: int


@dataclass(frozen=True)
class Resource:
    key: str
    section: str
    label: str
    file: str
    content_type: str

    @property
    def asset_name(self) -> str:
        return self.key + CONTENT_TYPES[self.content_type]


@dataclass(frozen=True)
class PayoutsConfig:
    """Tunables for payout-details storage (task 20261008-affiliate-payout-details)."""
    code_ttl_seconds: int          # emailed re-auth code lifetime
    proof_ttl_seconds: int         # lifetime of the single-use proof after a successful re-auth
    max_code_attempts: int         # wrong guesses allowed per issued code
    lockout_failures: int          # failed re-auths per user within lockout_minutes => locked
    lockout_minutes: int
    code_issues_per_hour: int      # codes emailed per user per hour
    retention_inactive_days: int   # hard-delete details untouched this long
    reveal_per_hour: int           # admin reveals per admin per hour
    max_body_bytes: int
    read_rate: str
    write_rate: str
    reauth_rate: str
    reveal_rate: str


_PAYOUT_INT_BOUNDS = {
    "code_ttl_seconds": (60, 900), "proof_ttl_seconds": (30, 300), "max_code_attempts": (1, 10),
    "lockout_failures": (1, 20), "lockout_minutes": (1, 1440), "code_issues_per_hour": (1, 30),
    "retention_inactive_days": (30, 3650), "reveal_per_hour": (1, 100), "max_body_bytes": (256, 8192),
}
_PAYOUT_RATE_KEYS = ("read_rate", "write_rate", "reauth_rate", "reveal_rate")


@dataclass(frozen=True)
class AffiliatesConfig:
    commission_rate: float
    milestones: tuple
    series_points: dict
    public_base_url: str
    code_link_format: str
    rate_limit: str
    resources: tuple
    payouts: PayoutsConfig

    def code_link(self, code: str) -> str:
        return self.code_link_format.replace("{base}", self.public_base_url.rstrip("/")).replace("{code}", code)


_cfg: AffiliatesConfig | None = None


def _err(msg: str) -> ConfigSectionError:
    return ConfigSectionError(f"affiliates.json[{SECTION}]: {msg}")


def _int(v, name: str, low: int, high: int) -> int:
    if isinstance(v, bool) or not isinstance(v, int) or v < low or v > high:
        raise _err(f"{name} must be an integer between {low} and {high}")
    return v


def _load_payouts(p: dict) -> PayoutsConfig:
    want = sorted(list(_PAYOUT_INT_BOUNDS) + list(_PAYOUT_RATE_KEYS))
    if sorted(p) != want:
        raise _err(f"payouts must contain exactly {want}")
    vals = {k: _int(p[k], f"payouts.{k}", lo, hi) for k, (lo, hi) in _PAYOUT_INT_BOUNDS.items()}
    for k in _PAYOUT_RATE_KEYS:
        if not isinstance(p[k], str):
            raise _err(f"payouts.{k} must be a rate-limit string")
        try:
            _parse_rate(p[k])
        except Exception:
            raise _err(f"payouts.{k} is not a valid rate limit") from None
        vals[k] = p[k]
    if vals["proof_ttl_seconds"] > vals["code_ttl_seconds"]:
        raise _err("payouts.proof_ttl_seconds must not exceed code_ttl_seconds")
    return PayoutsConfig(**vals)


def _load() -> AffiliatesConfig:
    raw = load_section(
        CONFIG_PATH, SECTION,
        required_keys=("commission_rate", "milestones", "series_points", "public_base_url",
                       "code_link_format", "rate_limit", "resources", "payouts"),
        types={"commission_rate": (int, float), "milestones": list, "series_points": dict,
               "public_base_url": str, "code_link_format": str, "rate_limit": str, "resources": list,
               "payouts": dict},
        rate_keys=("rate_limit",),
    )
    rate = raw["commission_rate"]
    if not (0 < rate <= 1):
        raise _err("commission_rate must be greater than 0 and at most 1")

    milestones, last = [], 0
    if not raw["milestones"]:
        raise _err("milestones must not be empty")
    for i, m in enumerate(raw["milestones"]):
        if not isinstance(m, dict) or sorted(m) != ["bonus_cents", "subscribers"]:
            raise _err(f"milestones[{i}] must have exactly subscribers and bonus_cents")
        subs = _int(m["subscribers"], f"milestones[{i}].subscribers", 1, 10_000_000)
        bonus = _int(m["bonus_cents"], f"milestones[{i}].bonus_cents", 0, 100_000_000)
        if subs <= last:
            raise _err("milestones must be in strictly ascending subscriber order")
        last = subs
        milestones.append(Milestone(subs, bonus))

    sp = raw["series_points"]
    if sorted(sp) != sorted(SERIES_UNITS):
        raise _err(f"series_points must contain exactly {list(SERIES_UNITS)}")
    points = {u: _int(sp[u], f"series_points.{u}", 2, 400) for u in SERIES_UNITS}

    base = raw["public_base_url"]
    if not re.fullmatch(r"https://[A-Za-z0-9.-]+(:\d+)?/?", base):
        raise _err("public_base_url must be an https origin")
    fmt = raw["code_link_format"]
    if "{base}" not in fmt or "{code}" not in fmt:
        raise _err("code_link_format must contain {base} and {code}")

    resources, keys = [], set()
    for i, r in enumerate(raw["resources"]):
        want = ["content_type", "file", "key", "label", "section"]
        if not isinstance(r, dict) or sorted(r) != want or not all(isinstance(r[k], str) for k in want):
            raise _err(f"resources[{i}] must have exactly {want} (strings)")
        if not _KEY_RE.match(r["key"]) or r["key"] in keys:
            raise _err(f"resources[{i}].key is invalid or duplicated")
        keys.add(r["key"])
        if r["section"] not in RESOURCE_SECTIONS:
            raise _err(f"resources[{i}].section must be one of {list(RESOURCE_SECTIONS)}")
        if r["content_type"] not in CONTENT_TYPES:
            raise _err(f"resources[{i}].content_type is not allowed")
        parts = Path(r["file"]).parts
        if not r["file"] or Path(r["file"]).is_absolute() or ".." in parts or not r["label"].strip():
            raise _err(f"resources[{i}] has an unsafe file path or empty label")
        resources.append(Resource(r["key"], r["section"], r["label"].strip(), r["file"], r["content_type"]))

    payouts = _load_payouts(raw["payouts"])
    return AffiliatesConfig(float(rate), tuple(milestones), points, base, fmt, raw["rate_limit"],
                            tuple(resources), payouts)


def get_affiliates_config() -> AffiliatesConfig:
    global _cfg
    if _cfg is None:
        _cfg = _load()
    return _cfg


def validate_affiliates_config() -> None:
    """Startup check: reload uncached so a file edited since import is re-read."""
    global _cfg
    _cfg = _load()


def reset_for_tests() -> None:
    global _cfg
    _cfg = None
