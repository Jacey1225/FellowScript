"""Validation and normalisation of listing content (no database, no HTTP).

Every public-facing text field passes through here before it is stored:

* structure and length limits come from ``listings_config`` (no constants for
  tunables here);
* facet values must be slugs from the controlled vocabulary;
* plain text fields (title, summary, church, place, tags) reject control and
  bidi characters, angle brackets and links;
* the description is a JSON array of typed blocks. Only ``text`` blocks exist
  in this task; the media task adds image/video validators by registering in
  ``BLOCK_VALIDATORS``. A text block is a restricted Markdown subset: raw HTML
  is rejected, links must be absolute http/https URLs to non-shortener, non-IP
  hosts, images are rejected (media arrive as their own block type);
* every text field goes through ``check_clean`` and the youth-term list
  (adult-only product, J5 Q3).

``ListingError`` is the one exception the manager raises; routes turn it into
an HTTP error with ``{"code", "message"[, "field"]}``.
"""
from __future__ import annotations

import ipaddress
import re
import unicodedata
from typing import Any, Callable, Mapping
from urllib.parse import urlsplit

from backend.interactions.listings_config import (
    ARRAY_VOCAB_FIELDS,
    SINGLE_VOCAB_FIELDS,
    ListingsConfig,
)
from backend.moderation.content_filter import ContentRejected, check_clean, rejection_message

YOUTH_MESSAGE = "Explore lists groups for adults 18 and over."


class ListingError(Exception):
    """A request the listing lifecycle refuses. ``status`` is the HTTP status."""

    def __init__(self, status: int, code: str, message: str | None = None, field: str | None = None):
        self.status = status
        self.code = code
        self.message = message or code.replace("_", " ").capitalize()
        self.field = field
        super().__init__(f"{code}")

    def detail(self) -> dict:
        d = {"code": self.code, "message": self.message}
        if self.field:
            d["field"] = self.field
        return d


# ISO 3166-1 alpha-2. Reference data, not a tunable.
ISO_COUNTRIES = frozenset(
    "AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW "
    "BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ "
    "FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ "
    "IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH "
    "MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL "
    "PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD "
    "TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW".split()
)

# Columns the owner can write. The keys of ``normalise``'s result are always a
# subset of this set, so the manager can build its UPDATE from them safely.
CONTENT_COLUMNS = frozenset(
    {
        "title", "summary", "description_blocks", "description_text",
        "denominations", "goals", "practices", "hobbies", "free_tags", "age_ranges",
        "life_stages", "languages", "gender_makeup", "meeting_format", "frequency",
        "country", "region", "city", "city_norm", "church_name",
    }
)
# Free-form public text: a change re-queues a published listing for review.
REVIEW_COLUMNS = frozenset(
    {"title", "summary", "description_blocks", "description_text", "church_name", "free_tags"}
)

_CONTROL_RE = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f\x7f‪-‮⁦-⁩]")
_URL_IN_PLAIN_RE = re.compile(r"(?i)(?:https?://|www\.|\b[a-z0-9-]+\.(?:com|net|org|io|co|me|ly|gl|app|xyz)/)")
_TAG_LIKE_RE = re.compile(r"<\s*[/!?A-Za-z]")
_INLINE_LINK_RE = re.compile(r"(!?)\[([^\]\n]*)\]\(\s*([^)\n]*?)\s*\)")
_REF_DEF_RE = re.compile(r"^[ ]{0,3}\[[^\]\n]+\]:[ \t]*(\S+)", re.MULTILINE)
_BARE_URL_RE = re.compile(r"(?i)\b(?:https?://|www\.)[^\s<>()\[\]]+")
_NUMERIC_HOST_RE = re.compile(r"^[0-9a-fx.]+$", re.IGNORECASE)
_TAG_CHARS_RE = re.compile(r"^[\w][\w '\-&.]*$", re.UNICODE)
_WS_RE = re.compile(r"\s+")
_MAX_URL_LEN = 500
_IMAGE_START_RE = re.compile(r"!\[")
# City / region: letters, spaces and . ' - , ( ) / only. No digits, so a phone number or a
# street address ("123 Main St") cannot ride along in a field that is not re-reviewed on edit.
_PLACE_RE = re.compile(r"^[^\W\d_](?:[^\W\d_]|[ '\u2019.,()/\-])*$", re.UNICODE)
_LEET = str.maketrans({"0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s", "!": "i"})


def _collapse(value: str) -> str:
    return _WS_RE.sub(" ", value).strip()


def _check_plain(field: str, value: str, *, allow_urls: bool = False) -> None:
    if _CONTROL_RE.search(value):
        raise ListingError(422, "invalid_text", "That text has characters we can't accept.", field)
    if "<" in value or ">" in value:
        raise ListingError(422, "html_not_allowed", "Please remove the < and > characters.", field)
    if not allow_urls and _URL_IN_PLAIN_RE.search(value):
        raise ListingError(422, "links_not_allowed", "Links aren't allowed in this field.", field)


def _plain_field(cfg_max: int, field: str, value: Any, *, required_str: bool = False) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ListingError(422, "invalid_field", f"{field} must be text.", field)
    cleaned = _collapse(value)
    if len(cleaned) > cfg_max:
        raise ListingError(422, "too_long", f"{field} must be {cfg_max} characters or fewer.", field)
    if cleaned:
        _check_plain(field, cleaned)
    return cleaned


def _place_field(cfg_max: int, field: str, value: Any) -> str | None:
    cleaned = _plain_field(cfg_max, field, value)
    if cleaned and not _PLACE_RE.fullmatch(cleaned):
        raise ListingError(
            422, "invalid_place",
            "Use a place name (letters only). Street addresses and numbers aren't allowed.", field,
        )
    return cleaned


def host_is_blocked(cfg: ListingsConfig, host: str) -> bool:
    """True for IP literals (any notation), single-label hosts and shorteners."""
    host = host.strip().lower().rstrip(".")
    if not host or "." not in host:
        return True
    if _NUMERIC_HOST_RE.fullmatch(host):
        return True
    try:
        ipaddress.ip_address(host.strip("[]"))
        return True
    except ValueError:
        pass
    if ":" in host or "[" in host:
        return True
    for blocked in cfg.blocked_link_hosts:
        if host == blocked or host.endswith("." + blocked):
            return True
    return False


def _check_link(cfg: ListingsConfig, url: str, field: str, *, require_scheme: bool) -> None:
    bad = ListingError(422, "invalid_link", "That link can't be used. Use a full https:// address.", field)
    if not url or len(url) > _MAX_URL_LEN or _CONTROL_RE.search(url) or "\\" in url or any(c.isspace() for c in url):
        raise bad
    candidate = url
    if not re.match(r"(?i)https?://", candidate):
        if require_scheme or not candidate.lower().startswith("www."):
            raise bad
        candidate = "https://" + candidate
    try:
        parts = urlsplit(candidate)
        port = parts.port
    except ValueError:
        raise bad from None
    if parts.scheme.lower() not in ("http", "https") or not parts.hostname or parts.username or parts.password:
        raise bad
    if port not in (None, 80, 443):
        raise bad
    if host_is_blocked(cfg, parts.hostname):
        raise ListingError(
            422, "link_blocked",
            "That link's address isn't allowed (link shorteners and IP addresses are blocked).", field,
        )


def validate_markdown_text(cfg: ListingsConfig, text: str, field: str) -> None:
    """Raise ``ListingError`` for anything outside the allowed Markdown subset."""
    if _CONTROL_RE.search(text):
        raise ListingError(422, "invalid_text", "That text has characters we can't accept.", field)
    if _TAG_LIKE_RE.search(text):
        raise ListingError(422, "html_not_allowed", "HTML isn't allowed in the description.", field)
    if _IMAGE_START_RE.search(text):
        # Reference-style (![alt][ref]) and shortcut (![ref]) images resolve through a
        # link definition that would otherwise pass as a plain https link.
        raise ListingError(422, "media_not_supported", "Images and videos are added separately.", field)
    for match in _INLINE_LINK_RE.finditer(text):
        bang, _label, target = match.groups()
        if bang:
            raise ListingError(422, "media_not_supported", "Images and videos are added separately.", field)
        first = target.split(None, 1)
        rest = first[1] if len(first) > 1 else ""
        if not first:
            raise ListingError(422, "invalid_link", "A link is missing its address.", field)
        if rest and not re.fullmatch(r'"[^"]*"|\'[^\']*\'', rest.strip()):
            raise ListingError(422, "invalid_link", "A link is malformed.", field)
        _check_link(cfg, first[0], field, require_scheme=True)
    for match in _REF_DEF_RE.finditer(text):
        _check_link(cfg, match.group(1), field, require_scheme=True)
    for match in _BARE_URL_RE.finditer(text):
        _check_link(cfg, match.group(0).rstrip(".,;:!?'\""), field, require_scheme=False)


_MD_STRIP_RES = (
    (re.compile(r"^[ \t]{0,3}(?:#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+|\d+[.)][ \t]+)", re.MULTILINE), ""),
    (re.compile(r"[*`~]+"), ""),
    (re.compile(r"(?<!\w)_+|_+(?!\w)"), ""),
)


def flatten_markdown(text: str) -> str:
    """Visible text of a text block: link targets and Markdown markers dropped."""
    out = _REF_DEF_RE.sub("", text)
    out = _INLINE_LINK_RE.sub(lambda m: m.group(2), out)
    for pattern, repl in _MD_STRIP_RES:
        out = pattern.sub(repl, out)
    return _collapse(out)


# -- description blocks -----------------------------------------------------------------

def _validate_text_block(cfg: ListingsConfig, block: Mapping, field: str) -> dict:
    if set(block) != {"type", "text"}:
        raise ListingError(422, "invalid_block", "A text block can only hold its text.", field)
    text = block["text"]
    if not isinstance(text, str):
        raise ListingError(422, "invalid_block", "A text block needs text.", field)
    text = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not text:
        raise ListingError(422, "invalid_block", "A text block can't be empty.", field)
    if len(text) > cfg.description_max_block_chars:
        raise ListingError(
            422, "too_long",
            f"A paragraph must be {cfg.description_max_block_chars} characters or fewer.", field,
        )
    validate_markdown_text(cfg, text, field)
    return {"type": "text", "text": text}


# Block type -> validator(cfg, block, field) -> normalised block. The media task
# registers image/video here; an unknown type is rejected.
BLOCK_VALIDATORS: dict[str, Callable[[ListingsConfig, Mapping, str], dict]] = {
    "text": _validate_text_block,
}


def normalise_description(cfg: ListingsConfig, blocks: Any) -> tuple[list[dict], str]:
    """Returns ``(normalised_blocks, description_text)``."""
    field = "description_blocks"
    if blocks is None:
        blocks = []
    if not isinstance(blocks, list):
        raise ListingError(422, "invalid_field", "The description must be a list of blocks.", field)
    if len(blocks) > cfg.description_max_blocks:
        raise ListingError(
            422, "too_many_blocks", f"The description can have at most {cfg.description_max_blocks} blocks.", field
        )
    out: list[dict] = []
    total = 0
    visible: list[str] = []
    for block in blocks:
        if not isinstance(block, Mapping) or not isinstance(block.get("type"), str):
            raise ListingError(422, "invalid_block", "Every block needs a type.", field)
        validator = BLOCK_VALIDATORS.get(block["type"])
        if validator is None:
            raise ListingError(422, "invalid_block", "That block type isn't supported.", field)
        clean = validator(cfg, block, field)
        out.append(clean)
        if clean["type"] == "text":
            total += len(clean["text"])
            if total > cfg.description_max_text_chars:
                raise ListingError(
                    422, "too_long",
                    f"The description must be {cfg.description_max_text_chars} characters or fewer.", field,
                )
            visible.append(flatten_markdown(clean["text"]))
    return out, _collapse(" ".join(v for v in visible if v))[: cfg.description_max_text_chars]


# -- facets ------------------------------------------------------------------------------

def _slug_list(cfg: ListingsConfig, field: str, vocab_key: str, value: Any) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, (list, tuple)):
        raise ListingError(422, "invalid_field", f"{field} must be a list.", field)
    allowed = cfg.vocab_slugs(vocab_key)
    out: list[str] = []
    for item in value:
        if not isinstance(item, str):
            raise ListingError(422, "invalid_vocab", f"{field} has an invalid value.", field)
        slug = item.strip().lower()
        if slug not in allowed:
            raise ListingError(422, "invalid_vocab", f"{field} has a value we don't recognise.", field)
        if slug not in out:
            out.append(slug)
    if len(out) > cfg.max_values_per_field:
        raise ListingError(422, "too_many_values", f"Choose up to {cfg.max_values_per_field} for {field}.", field)
    return out


def _slug_single(cfg: ListingsConfig, field: str, vocab_key: str, value: Any) -> str | None:
    if value is None or value == "":
        return None
    if not isinstance(value, str) or value.strip().lower() not in cfg.vocab_slugs(vocab_key):
        raise ListingError(422, "invalid_vocab", f"{field} has a value we don't recognise.", field)
    return value.strip().lower()


def _free_tags(cfg: ListingsConfig, value: Any) -> list[str]:
    field = "free_tags"
    if value is None:
        return []
    if not isinstance(value, (list, tuple)):
        raise ListingError(422, "invalid_field", "free_tags must be a list.", field)
    out: list[str] = []
    seen: set[str] = set()
    for item in value:
        if not isinstance(item, str):
            raise ListingError(422, "invalid_field", "Each tag must be text.", field)
        tag = _collapse(item)
        if not tag:
            continue
        if len(tag) > cfg.free_tag_max_length:
            raise ListingError(
                422, "too_long", f"A tag must be {cfg.free_tag_max_length} characters or fewer.", field
            )
        if not _TAG_CHARS_RE.fullmatch(tag) or _CONTROL_RE.search(tag) or _URL_IN_PLAIN_RE.search(tag):
            raise ListingError(422, "invalid_text", "Tags can use letters, numbers, spaces and - ' & .", field)
        key = tag.casefold()
        if key not in seen:
            seen.add(key)
            out.append(tag)
    if len(out) > cfg.max_free_tags:
        raise ListingError(422, "too_many_values", f"Use up to {cfg.max_free_tags} tags.", field)
    return out


def city_norm(city: str | None) -> str | None:
    if not city:
        return None
    return _collapse(unicodedata.normalize("NFKC", city)).casefold() or None


# -- the entry point ----------------------------------------------------------------------

def normalise(cfg: ListingsConfig, data: Mapping[str, Any]) -> dict:
    """Validate the fields present in ``data`` and return column values.

    Only keys present in ``data`` are validated and returned (omitted fields
    mean "unchanged"). The result's keys are a subset of ``CONTENT_COLUMNS``.
    Raises ``ListingError`` (422) on the first problem.
    """
    out: dict[str, Any] = {}
    if "title" in data:
        out["title"] = _plain_field(cfg.title_max_length, "title", data["title"]) or ""
    if "summary" in data:
        out["summary"] = _plain_field(cfg.summary_max_length, "summary", data["summary"]) or None
    if "church_name" in data:
        out["church_name"] = _plain_field(cfg.church_name_max_length, "church_name", data["church_name"]) or None
    if "region" in data:
        out["region"] = _place_field(cfg.region_max_length, "region", data["region"]) or None
    if "city" in data:
        city = _place_field(cfg.city_max_length, "city", data["city"]) or None
        out["city"] = city
        out["city_norm"] = city_norm(city)
    if "country" in data:
        country = data["country"]
        if country in (None, ""):
            out["country"] = None
        else:
            if not isinstance(country, str) or country.strip().upper() not in ISO_COUNTRIES:
                raise ListingError(422, "invalid_field", "country must be a two-letter country code.", "country")
            out["country"] = country.strip().upper()
    for field, vocab_key in ARRAY_VOCAB_FIELDS.items():
        if field in data:
            out[field] = _slug_list(cfg, field, vocab_key, data[field])
    for field, vocab_key in SINGLE_VOCAB_FIELDS.items():
        if field in data:
            out[field] = _slug_single(cfg, field, vocab_key, data[field])
    if "free_tags" in data:
        out["free_tags"] = _free_tags(cfg, data["free_tags"])
    if "description_blocks" in data:
        blocks, text = normalise_description(cfg, data["description_blocks"])
        out["description_blocks"] = blocks
        out["description_text"] = text
    reject_unsafe_text(cfg, out)
    return out


def match_forms(text: str) -> tuple[str, ...]:
    """Forms of ``text`` the word filters look at: the text itself plus a canonical
    form (NFKD, combining marks and invisible format characters such as zero-width
    spaces dropped, so full-width letters and 'te<ZWSP>en' do not slip past) and a
    leetspeak-folded copy of that ('t33n'). The stored text is never altered."""
    decomposed = unicodedata.normalize("NFKD", text)
    canonical = "".join(ch for ch in decomposed if unicodedata.category(ch) not in ("Mn", "Cf"))
    forms = [text]
    for form in (canonical, canonical.translate(_LEET)):
        if form not in forms:
            forms.append(form)
    return tuple(forms)


def reject_unsafe_text(cfg: ListingsConfig, values: Mapping[str, Any]) -> None:
    """Youth-term list and ``check_clean`` over every free-text value present."""
    texts: dict[str, str] = {}
    for field in ("title", "summary", "church_name", "region", "city", "description_text"):
        if values.get(field):
            texts[field] = values[field]
    if values.get("free_tags"):
        texts["free_tags"] = " ; ".join(values["free_tags"])
    for field, text in texts.items():
        if any(cfg.youth_pattern.search(form) for form in match_forms(text)):
            raise ListingError(422, "youth_not_supported", YOUTH_MESSAGE, field)
    for field, text in texts.items():
        for form in match_forms(text)[:2]:  # original + canonical (check_clean folds leetspeak itself)
            try:
                check_clean(**{field: form})
            except ContentRejected as e:
                raise ListingError(422, "content_rejected", rejection_message(e), field) from None


def options_payload(cfg: ListingsConfig) -> dict:
    """What the owner form needs: vocabularies and limits (no secrets)."""
    return {
        "vocab": {key: [{"slug": s, "label": l} for s, l in pairs] for key, pairs in cfg.vocab.items()},
        "limits": {
            "title": cfg.title_max_length,
            "summary": cfg.summary_max_length,
            "church_name": cfg.church_name_max_length,
            "region": cfg.region_max_length,
            "city": cfg.city_max_length,
            "max_values_per_field": cfg.max_values_per_field,
            "max_free_tags": cfg.max_free_tags,
            "free_tag_max_length": cfg.free_tag_max_length,
            "description_max_blocks": cfg.description_max_blocks,
            "description_max_text_chars": cfg.description_max_text_chars,
            "description_max_block_chars": cfg.description_max_block_chars,
            "per_owner_cap": cfg.per_owner_cap,
        },
        "block_types": sorted(BLOCK_VALIDATORS),
        "countries": sorted(ISO_COUNTRIES),
        "consent_version": cfg.consent_version,
        "support_email": cfg.support_email,
        "require_approval": cfg.require_approval,
    }


# The media task registers the ``image`` and ``video`` block validators here, at the
# end, once every name above exists (``listings_media`` imports this module too;
# either import order works because it only reads names defined above).
from backend.interactions import listings_media  # noqa: E402,F401
