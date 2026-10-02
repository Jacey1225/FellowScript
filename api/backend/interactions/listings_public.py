"""Public (signed-out) read side of Explorer listings.

Everything here is synchronous and runs through ``public_guard.run_public``
(dedicated thread limiter, 429 ``busy`` shedding, never 5xx). Each call opens
its OWN connection (``public_guard.public_connection``: one transaction, ``SET
LOCAL statement_timeout`` from config) and never touches ``DBManager``.

Rules this module enforces:
* The ``explorer_browse`` flag is checked first, fail closed; off is the same
  uniform 404 as a missing listing (no existence oracle, no flag oracle).
* Every query is built on ``listings.public_where()``; filters are bound
  parameters, vocabulary values are validated against config BEFORE any SQL
  (422), the keyset cursor is validated by the shared codec on
  ``(published_at, public_id)`` with ``id_type='text'`` so no internal id is
  ever in a cursor.
* Responses are built field by field into the allowlisted models in
  ``schemas.explorer_public``. The row is never serialised.
* Size bucket and open/full flag for a page come out of the list query itself
  (one lateral aggregate over ``groups.LIVE_MEMBER_JOIN``), so the number of SQL
  statements does not grow with page size.
* No listing text, filter values, cursor values or ids in logs.
"""
from typing import Mapping

from fastapi import HTTPException

from backend import public_guard
from backend.interactions import flags, paging
from backend.interactions.groups import LIVE_MEMBER_JOIN
from backend.interactions.listing_content import ISO_COUNTRIES, city_norm
from backend.interactions.listings import is_public_id, listing_requestable, public_where
from backend.interactions.listings_config import (
    ARRAY_VOCAB_FIELDS,
    SINGLE_VOCAB_FIELDS,
    ListingsConfig,
    get_listings_config,
)
from backend.observability import feature_summary
from schemas.explorer_public import (
    FilterLimits,
    ListingCard,
    ListingDetail,
    ListingPage,
    PageInfo,
    PublicFilters,
    VocabOption,
)

# Public vocabulary keys exposed to signed-out browsers (the rest of the vocab
# section is for the owner form only).
PUBLIC_VOCAB_KEYS = (
    "denominations", "goals", "practices", "hobbies", "age_ranges", "life_stages",
    "languages", "gender_makeup", "meeting_formats", "frequencies",
)

_LIST_COLUMNS = (
    "gl.public_id, gl.title, gl.summary, gl.denominations, gl.goals, gl.practices, gl.hobbies, "
    "gl.free_tags, gl.age_ranges, gl.life_stages, gl.languages, gl.gender_makeup, gl.meeting_format, "
    "gl.frequency, gl.country, gl.region, gl.city, gl.church_name, gl.published_at"
)
_COLUMN_KEYS = (
    "public_id", "title", "summary", "denominations", "goals", "practices", "hobbies",
    "free_tags", "age_ranges", "life_stages", "languages", "gender_makeup", "meeting_format",
    "frequency", "country", "region", "city", "church_name", "published_at",
)
_ARRAY_KEYS = (
    "denominations", "goals", "practices", "hobbies", "free_tags", "age_ranges", "life_stages", "languages",
)
# Distinct live members of the group, computed against LIVE_MEMBER_JOIN (alias g).
_MEMBER_COUNT_LATERAL = (
    "LEFT JOIN LATERAL (SELECT count(DISTINCT u._id) AS n " + LIVE_MEMBER_JOIN + ") mc ON TRUE"
)


def _not_found() -> HTTPException:
    feature_summary.incr("public_404")
    return HTTPException(status_code=404, detail={"code": "not_found", "message": "Not found"})


def _invalid(field: str) -> HTTPException:
    # Never echoes the offending value.
    return HTTPException(status_code=422, detail={"code": "invalid_filter", "field": field})


def require_browse() -> None:
    """Uniform 404 unless ``explorer_browse`` is on (fail closed)."""
    try:
        enabled = bool(flags.is_enabled("explorer_browse"))
    except Exception:  # noqa: BLE001 - fail closed
        enabled = False
    if not enabled:
        raise _not_found()


# -- vocabulary (public source for the signed-out filter UI) -------------------------

def filters_payload(cfg: ListingsConfig) -> PublicFilters:
    return PublicFilters(
        vocab={
            key: [VocabOption(slug=s, label=l) for s, l in cfg.vocab[key]]
            for key in PUBLIC_VOCAB_KEYS
        },
        countries=sorted(ISO_COUNTRIES),
        size_buckets=[label for _max, label in cfg.size_buckets],
        limits=FilterLimits(
            page_size_default=cfg.page_size_default,
            page_size_max=cfg.page_size_max,
            max_facet_values=cfg.max_facet_values,
            max_facets=cfg.max_facets,
            q_max_length=cfg.q_max_length,
            city_max_length=cfg.city_max_length,
            region_max_length=cfg.region_max_length,
        ),
        support_email=cfg.support_email,
    )


def get_filters() -> PublicFilters:
    require_browse()
    feature_summary.incr("public_requests")
    return filters_payload(get_listings_config())


# -- request parsing (422 before any SQL) ------------------------------------------------

def _clean_text(value: str, field: str, max_len: int) -> str:
    value = value.strip()
    if len(value) > max_len or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise _invalid(field)
    return value


def _like_prefix(value: str) -> str:
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"


def _slug_values(query_params, name: str, allowed: frozenset, cfg: ListingsConfig) -> list[str]:
    out: list[str] = []
    for raw in query_params.getlist(name):
        for part in raw.split(","):
            slug = part.strip()
            if not slug:
                continue
            if slug not in allowed:
                raise _invalid(name)
            if slug not in out:
                out.append(slug)
    if len(out) > cfg.max_facet_values:
        raise _invalid(name)
    return out


def parse_filters(query_params, cfg: ListingsConfig) -> dict:
    """Validate every filter parameter against config. Returns a dict of the
    filters that are set. Unknown parameter names are ignored."""
    filters: dict = {}
    for field, vocab_key in ARRAY_VOCAB_FIELDS.items():
        values = _slug_values(query_params, field, cfg.vocab_slugs(vocab_key), cfg)
        if values:
            filters[field] = values
    for field, vocab_key in SINGLE_VOCAB_FIELDS.items():
        values = _slug_values(query_params, field, cfg.vocab_slugs(vocab_key), cfg)
        if len(values) > 1:
            raise _invalid(field)
        if values:
            filters[field] = values[0]
    country = query_params.get("country")
    if country is not None and country.strip():
        code = country.strip().upper()
        if code not in ISO_COUNTRIES:
            raise _invalid("country")
        filters["country"] = code
    region = query_params.get("region")
    if region is not None and region.strip():
        filters["region"] = _clean_text(region, "region", cfg.region_max_length)
    city = query_params.get("city")
    if city is not None and city.strip():
        cleaned = _clean_text(city, "city", cfg.city_max_length)
        normalised = city_norm(cleaned)
        if normalised:
            filters["city"] = normalised
    if len(filters) > cfg.max_facets:
        raise _invalid("filters")
    return filters


def parse_q(query_params, cfg: ListingsConfig) -> str | None:
    q = query_params.get("q")
    if q is None or not q.strip():
        return None
    return _clean_text(q, "q", cfg.q_max_length)


def parse_include_full(query_params) -> bool:
    raw = query_params.get("include_full")
    if raw is None or raw == "":
        return False
    if raw.lower() in ("true", "1"):
        return True
    if raw.lower() in ("false", "0"):
        return False
    raise _invalid("include_full")


def parse_limit(query_params, cfg: ListingsConfig) -> int:
    raw = query_params.get("limit")
    if raw is None or raw == "":
        return cfg.page_size_default
    if not raw.isascii() or not raw.isdigit() or len(raw) > 6:
        raise _invalid("limit")
    return paging.clamp_limit(int(raw), cfg.page_size_default, cfg.page_size_max)


# -- row -> allowlisted model ------------------------------------------------------------

def _bucket(cfg: ListingsConfig, count: int) -> str:
    for max_members, label in cfg.size_buckets:
        if max_members is None or count <= max_members:
            return label
    return cfg.size_buckets[-1][1]


def _card_fields(cfg: ListingsConfig, row: tuple, max_members, member_count) -> dict:
    values = dict(zip(_COLUMN_KEYS, row))
    count = int(member_count or 0)
    full = max_members is not None and count >= max_members
    out = {key: values[key] for key in _COLUMN_KEYS if key != "published_at"}
    for key in _ARRAY_KEYS:
        out[key] = list(values[key] or [])
    out["country"] = values["country"].strip() if values["country"] else None
    out["size_bucket"] = _bucket(cfg, count)
    out["seats"] = "full" if full else "open"
    out["published_at"] = paging.format_timestamp(values["published_at"])
    return out


def _public_blocks(blocks) -> list[dict]:
    """Rebuild description blocks field by field. Only the block types this
    task knows are emitted (text); an unknown type is dropped, never passed on."""
    out: list[dict] = []
    for block in blocks or []:
        if isinstance(block, Mapping) and block.get("type") == "text" and isinstance(block.get("text"), str):
            out.append({"type": "text", "text": block["text"]})
    return out


# -- list ---------------------------------------------------------------------------------

def list_listings(query_params) -> ListingPage:
    """Facet filters (GIN ``&&``: any value within a facet, AND across facets), ``q``
    full-text filter, keyset page ordered by ``(published_at DESC, public_id DESC)``."""
    require_browse()
    feature_summary.incr("public_requests")
    cfg = get_listings_config()
    filters = parse_filters(query_params, cfg)
    q = parse_q(query_params, cfg)
    include_full = parse_include_full(query_params)
    limit = parse_limit(query_params, cfg)
    cursor = paging.decode_cursor(query_params, id_type="text", with_seq=False)

    where = [public_where("gl")]
    params: list = []
    for field in ARRAY_VOCAB_FIELDS:
        if field in filters:
            where.append(f"gl.{field} && %s::text[]")
            params.append(filters[field])
    for field in SINGLE_VOCAB_FIELDS:
        if field in filters:
            where.append(f"gl.{field} = %s")
            params.append(filters[field])
    if "country" in filters:
        where.append("gl.country = %s")
        params.append(filters["country"])
    if "region" in filters:
        where.append("lower(gl.region) LIKE lower(%s)")
        params.append(_like_prefix(filters["region"]))
    if "city" in filters:
        where.append("gl.city_norm LIKE %s")
        params.append(_like_prefix(filters["city"]))
    if q is not None:
        where.append("gl.search_tsv @@ plainto_tsquery('simple', %s)")
        params.append(q)
    if not include_full:
        where.append("(g.max_members IS NULL OR COALESCE(mc.n, 0) < g.max_members)")
    if cursor is not None:
        where.append(f"(gl.published_at, gl.public_id) < (%s::timestamptz, {cursor.id_sql})")
        params.extend([cursor.timestamp, cursor.id])
    sql = (
        f"SELECT {_LIST_COLUMNS}, g.max_members, COALESCE(mc.n, 0) "
        "FROM group_listings gl JOIN groups g ON g._id = gl.group_id "
        f"{_MEMBER_COUNT_LATERAL} "
        "WHERE " + " AND ".join(where) + " "
        "ORDER BY gl.published_at DESC, gl.public_id DESC LIMIT %s"
    )
    params.append(limit + 1)

    with public_guard.public_connection(cfg.public_query_timeout_ms) as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            rows = cur.fetchall()

    has_more = len(rows) > limit
    rows = rows[:limit]
    cards = [ListingCard(**_card_fields(cfg, r[:-2], r[-2], r[-1])) for r in rows]
    next_cursor = None
    if has_more and rows:
        last = dict(zip(_COLUMN_KEYS, rows[-1][:-2]))
        next_cursor = paging.encode_cursor(last["published_at"], None, last["public_id"])
    page = paging.envelope("listings", [], limit, has_more, next_cursor)["page"]
    return ListingPage(listings=cards, page=PageInfo(**page))


# -- detail -------------------------------------------------------------------------------

def get_listing(public_id: str) -> ListingDetail:
    require_browse()
    feature_summary.incr("public_requests")
    if not is_public_id(public_id):
        raise _not_found()
    cfg = get_listings_config()
    sql = (
        f"SELECT {_LIST_COLUMNS}, gl.description_blocks, g.max_members, COALESCE(mc.n, 0) "
        "FROM group_listings gl JOIN groups g ON g._id = gl.group_id "
        f"{_MEMBER_COUNT_LATERAL} "
        f"WHERE gl.public_id = %s AND {public_where('gl')}"
    )
    with public_guard.public_connection(cfg.public_query_timeout_ms) as conn:
        with conn.cursor() as cur:
            cur.execute(sql, (public_id,))
            row = cur.fetchone()
            if row is None:
                raise _not_found()
            requestable = listing_requestable(cur, public_id) is not None
    fields = _card_fields(cfg, row[:-3], row[-2], row[-1])
    return ListingDetail(
        **fields,
        description_blocks=_public_blocks(row[-3]),
        requestable=requestable,
    )
