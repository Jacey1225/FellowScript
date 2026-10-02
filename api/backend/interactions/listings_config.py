"""Validated tunables for Explorer listings (``api/config/explorer.json``,
section ``listings``).

Loaded through the shared ``config_loader`` (every key required, unknown keys
and wrong types rejected, no implicit defaults) and cached after the first
successful load. ``validate_listings_config()`` runs from ``startup_checks`` so a
bad file refuses to boot; it also calls ``public_guard.configure`` once because
that helper carries no defaults of its own (round-3 R3-m2). Nothing in this
module touches S3 or media (LSM adds its own ``media`` section later).

Vocabulary lists are controlled: a listing can only carry slugs defined here,
so filter facets stay a closed set (J5 Q5).
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from limits import parse as _parse_rate

from backend.config_loader import ConfigSectionError, load_section

CONFIG_PATH = Path(__file__).resolve().parents[2] / "config" / "explorer.json"
SECTION = "listings"

# Facets that are arrays of slugs on the listing row (GIN filtered), and the
# single-value ones; the value is the vocab key each is validated against.
ARRAY_VOCAB_FIELDS = {
    "denominations": "denominations",
    "goals": "goals",
    "practices": "practices",
    "hobbies": "hobbies",
    "age_ranges": "age_ranges",
    "life_stages": "life_stages",
    "languages": "languages",
}
SINGLE_VOCAB_FIELDS = {
    "gender_makeup": "gender_makeup",
    "meeting_format": "meeting_formats",
    "frequency": "frequencies",
}
VOCAB_KEYS = tuple(sorted(set(ARRAY_VOCAB_FIELDS.values()) | set(SINGLE_VOCAB_FIELDS.values())))

RATE_LIMIT_KEYS = ("list", "detail", "config", "owner_read", "owner_write", "report", "admin")

_SLUG_RE = re.compile(r"^[a-z0-9_]{1,40}$")
_CODE_RE = re.compile(r"^[a-z_]{1,32}$")
_HOST_RE = re.compile(r"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$")
_MAX_LABEL = 60


@dataclass(frozen=True)
class ListingsConfig:
    require_approval: bool
    consent_version: str
    per_owner_cap: int
    title_max_length: int
    summary_max_length: int
    church_name_max_length: int
    region_max_length: int
    city_max_length: int
    max_values_per_field: int
    max_free_tags: int
    free_tag_max_length: int
    description_max_blocks: int
    description_max_text_chars: int
    description_max_block_chars: int
    page_size_default: int
    page_size_max: int
    max_facet_values: int
    max_facets: int
    q_max_length: int
    public_query_timeout_ms: int
    public_global_rate_limit: str
    public_concurrency: int
    public_max_waiting: int
    report_auto_hide_threshold: int
    sweeper_interval_seconds: int
    sweeper_batch_size: int
    support_email: str
    rate_limits: dict
    reject_reason_codes: tuple
    hide_reason_codes: tuple
    youth_terms: tuple
    blocked_link_hosts: tuple
    size_buckets: tuple          # ((max_members | None, label), ...)
    vocab: dict                  # vocab key -> ((slug, label), ...)
    youth_pattern: "re.Pattern"  # compiled from youth_terms

    def vocab_slugs(self, vocab_key: str) -> frozenset:
        return frozenset(slug for slug, _label in self.vocab[vocab_key])


_INT_KEYS = (
    "per_owner_cap", "title_max_length", "summary_max_length", "church_name_max_length",
    "region_max_length", "city_max_length", "max_values_per_field", "max_free_tags",
    "free_tag_max_length", "description_max_blocks", "description_max_text_chars",
    "description_max_block_chars", "page_size_default", "page_size_max", "max_facet_values",
    "max_facets", "q_max_length", "public_query_timeout_ms", "public_concurrency",
    "public_max_waiting", "report_auto_hide_threshold", "sweeper_interval_seconds",
    "sweeper_batch_size",
)
_REQUIRED = _INT_KEYS + (
    "require_approval", "consent_version", "public_global_rate_limit", "support_email",
    "rate_limits", "reject_reason_codes", "hide_reason_codes", "youth_terms",
    "blocked_link_hosts", "size_buckets", "vocab",
)
_TYPES = {k: int for k in _INT_KEYS}
_TYPES.update({
    "require_approval": bool, "consent_version": str, "public_global_rate_limit": str,
    "support_email": str, "rate_limits": dict, "reject_reason_codes": list,
    "hide_reason_codes": list, "youth_terms": list, "blocked_link_hosts": list,
    "size_buckets": list, "vocab": dict,
})

# Hard ceilings tied to the DDL column widths (group_listings): a config value
# larger than the column would make every save fail with a database error.
_COLUMN_CEILINGS = {
    "title_max_length": 80,
    "summary_max_length": 280,
    "church_name_max_length": 120,
}

_cached: ListingsConfig | None = None


def _err(msg: str) -> ConfigSectionError:
    return ConfigSectionError(f"explorer.json[{SECTION}]: {msg}")


def _str_list(name: str, value, pattern: re.Pattern | None = None, lower: bool = False) -> tuple:
    if not value:
        raise _err(f"{name} must be a non-empty list")
    out = []
    for item in value:
        if not isinstance(item, str) or not item.strip() or len(item) > 64:
            raise _err(f"{name} must hold non-empty strings of at most 64 characters")
        item = item.strip().lower() if lower else item.strip()
        if pattern is not None and not pattern.fullmatch(item):
            raise _err(f"{name} has an invalid entry")
        out.append(item)
    if len(set(out)) != len(out):
        raise _err(f"{name} has duplicate entries")
    return tuple(out)


def _build_youth_pattern(terms: tuple) -> "re.Pattern":
    parts = []
    for term in sorted(terms, key=len, reverse=True):
        parts.append(r"\s+".join(re.escape(piece) for piece in term.split()))
    return re.compile(r"(?<![a-z0-9])(?:" + "|".join(parts) + r")(?![a-z0-9])", re.IGNORECASE)


def _load() -> ListingsConfig:
    raw = load_section(CONFIG_PATH, SECTION, required_keys=_REQUIRED, types=_TYPES)
    for key in _INT_KEYS:
        if raw[key] < 1:
            raise _err(f"{key} must be >= 1")
    for key, ceiling in _COLUMN_CEILINGS.items():
        if raw[key] > ceiling:
            raise _err(f"{key} cannot exceed {ceiling} (database column width)")
    if raw["page_size_default"] > raw["page_size_max"]:
        raise _err("page_size_default must not exceed page_size_max")
    if not raw["consent_version"].strip() or len(raw["consent_version"]) > 40:
        raise _err("consent_version must be a short non-empty string")
    if "@" not in raw["support_email"] or len(raw["support_email"]) > 254:
        raise _err("support_email is not valid")
    try:
        _parse_rate(raw["public_global_rate_limit"])
    except Exception as e:
        raise _err(f"public_global_rate_limit is not a valid rate limit: {e}") from None
    rates = raw["rate_limits"]
    if set(rates) != set(RATE_LIMIT_KEYS):
        raise _err(f"rate_limits must contain exactly {list(RATE_LIMIT_KEYS)}")
    for key, value in rates.items():
        try:
            if not isinstance(value, str):
                raise ValueError("not a string")
            _parse_rate(value)
        except Exception as e:
            raise _err(f"rate_limits.{key} is not a valid rate limit: {e}") from None

    reject_codes = _str_list("reject_reason_codes", raw["reject_reason_codes"], _CODE_RE)
    hide_codes = _str_list("hide_reason_codes", raw["hide_reason_codes"], _CODE_RE)
    youth_terms = _str_list("youth_terms", raw["youth_terms"], lower=True)
    hosts = _str_list("blocked_link_hosts", raw["blocked_link_hosts"], _HOST_RE, lower=True)

    buckets = []
    last = 0
    items = raw["size_buckets"]
    if not items:
        raise _err("size_buckets must not be empty")
    for index, item in enumerate(items):
        if not isinstance(item, dict) or set(item) != {"max_members", "label"}:
            raise _err("size_buckets entries need exactly max_members and label")
        mx, label = item["max_members"], item["label"]
        if not isinstance(label, str) or not label.strip() or len(label) > 20:
            raise _err("size_buckets label is invalid")
        if index == len(items) - 1:
            if mx is not None:
                raise _err("the last size bucket must have max_members null")
        else:
            if isinstance(mx, bool) or not isinstance(mx, int) or mx <= last:
                raise _err("size_buckets max_members must be increasing integers")
            last = mx
        buckets.append((mx, label.strip()))

    vocab_raw = raw["vocab"]
    if set(vocab_raw) != set(VOCAB_KEYS):
        raise _err(f"vocab must contain exactly {list(VOCAB_KEYS)}")
    vocab = {}
    for key in VOCAB_KEYS:
        entries = vocab_raw[key]
        if not isinstance(entries, list) or not entries:
            raise _err(f"vocab.{key} must be a non-empty list")
        pairs = []
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != {"slug", "label"}:
                raise _err(f"vocab.{key} entries need exactly slug and label")
            slug, label = entry["slug"], entry["label"]
            if not isinstance(slug, str) or not _SLUG_RE.fullmatch(slug):
                raise _err(f"vocab.{key} has an invalid slug")
            if not isinstance(label, str) or not label.strip() or len(label) > _MAX_LABEL:
                raise _err(f"vocab.{key} has an invalid label")
            pairs.append((slug, label.strip()))
        if len({s for s, _ in pairs}) != len(pairs):
            raise _err(f"vocab.{key} has duplicate slugs")
        vocab[key] = tuple(pairs)

    # Adult-only product: the age facet can never offer a minor range.
    for slug, _label in vocab["age_ranges"]:
        lead = re.match(r"\d+", slug)
        if lead and int(lead.group()) < 18:
            raise _err("age_ranges must start at 18")

    return ListingsConfig(
        require_approval=raw["require_approval"],
        consent_version=raw["consent_version"].strip(),
        per_owner_cap=raw["per_owner_cap"],
        title_max_length=raw["title_max_length"],
        summary_max_length=raw["summary_max_length"],
        church_name_max_length=raw["church_name_max_length"],
        region_max_length=raw["region_max_length"],
        city_max_length=raw["city_max_length"],
        max_values_per_field=raw["max_values_per_field"],
        max_free_tags=raw["max_free_tags"],
        free_tag_max_length=raw["free_tag_max_length"],
        description_max_blocks=raw["description_max_blocks"],
        description_max_text_chars=raw["description_max_text_chars"],
        description_max_block_chars=raw["description_max_block_chars"],
        page_size_default=raw["page_size_default"],
        page_size_max=raw["page_size_max"],
        max_facet_values=raw["max_facet_values"],
        max_facets=raw["max_facets"],
        q_max_length=raw["q_max_length"],
        public_query_timeout_ms=raw["public_query_timeout_ms"],
        public_global_rate_limit=raw["public_global_rate_limit"],
        public_concurrency=raw["public_concurrency"],
        public_max_waiting=raw["public_max_waiting"],
        report_auto_hide_threshold=raw["report_auto_hide_threshold"],
        sweeper_interval_seconds=raw["sweeper_interval_seconds"],
        sweeper_batch_size=raw["sweeper_batch_size"],
        support_email=raw["support_email"].strip(),
        rate_limits=dict(rates),
        reject_reason_codes=reject_codes,
        hide_reason_codes=hide_codes,
        youth_terms=youth_terms,
        blocked_link_hosts=hosts,
        size_buckets=tuple(buckets),
        vocab=vocab,
        youth_pattern=_build_youth_pattern(youth_terms),
    )


def get_listings_config() -> ListingsConfig:
    """Validated config, loaded once. Raises ``ConfigSectionError``; never defaults."""
    global _cached
    if _cached is None:
        _cached = _load()
    return _cached


def validate_listings_config() -> None:
    """Startup check: load (uncached) and configure the public guard.

    ``public_guard.configure`` is idempotent for equal values, so calling this
    again after a reload with the same numbers is a no-op.
    """
    global _cached
    cfg = _load()
    _cached = cfg
    from backend import public_guard

    public_guard.configure(cfg.public_concurrency, cfg.public_max_waiting)


def reset_for_tests() -> None:
    global _cached
    _cached = None
