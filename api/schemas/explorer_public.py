"""Public (signed-out) Explorer response contracts.

These are ALLOWLISTS: every model is built field by field from a listing row
by ``backend.interactions.listings_public`` and a row is never serialised
directly. Nothing here can carry the group id, the internal listing id, user
ids, usernames, emails, invite state or the member list. ``extra="forbid"``
makes adding a field a deliberate edit to this file.

Contract freeze (end of backend step 4): URL shapes
``GET /explorer/config``, ``GET /explorer/filters``,
``GET /explorer/listings`` and ``GET /explorer/listings/{public_id}``; the
only identifier a client ever sees is the 10-character ``public_id``.
Media fields (media task): ``photo_url`` on every card, ``banner_url`` / ``banner_alt`` on the
detail, and ``image`` / ``video`` description blocks. URLs are short-lived presigned GETs
issued by the server; a client never builds a storage URL itself.
"""
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ListingCard(_Strict):
    public_id: str
    title: str
    summary: str | None
    denominations: list[str]
    goals: list[str]
    practices: list[str]
    hobbies: list[str]
    free_tags: list[str]
    age_ranges: list[str]
    life_stages: list[str]
    languages: list[str]
    gender_makeup: str | None
    meeting_format: str | None
    frequency: str | None
    country: str | None
    region: str | None
    city: str | None
    church_name: str | None
    size_bucket: str
    seats: Literal["open", "full"]
    published_at: str
    photo_url: str | None = None


class ListingDetail(ListingCard):
    # Allowlisted blocks, rebuilt field by field: text {"type","text"}, image
    # {"type","url","alt","width","height"}, video (only while enabled)
    # {"type","provider","video_id","title"}.
    description_blocks: list[dict[str, Any]]
    banner_url: str | None = None
    banner_alt: str | None = None
    # True when a person could ask to join right now (listing_requestable).
    requestable: bool


class PageInfo(_Strict):
    limit: int
    has_more: bool
    next_cursor_timestamp: str | None
    next_cursor_seq: None = None
    next_cursor_id: str | None


class ListingPage(_Strict):
    listings: list[ListingCard]
    page: PageInfo


class VocabOption(_Strict):
    slug: str
    label: str


class FilterLimits(_Strict):
    page_size_default: int
    page_size_max: int
    max_facet_values: int
    max_facets: int
    q_max_length: int
    city_max_length: int
    region_max_length: int


class PublicFilters(_Strict):
    """Signed-out filter vocabulary: the same controlled lists the owner form
    uses, trimmed to what browsing needs (no consent, no owner limits)."""
    vocab: dict[str, list[VocabOption]]
    countries: list[str]
    size_buckets: list[str]
    limits: FilterLimits
    support_email: str
