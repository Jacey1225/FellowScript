"""Pure validators for announcement attachments (task 20261009-announcements-advanced, part E).

No DB, no I/O. Everything raises ``ValueError`` (the routes map that to 422)
and never coerces: bad input is rejected, not repaired.

* Links: http/https only, capped, no credentials in the URL.
* Payment handles: DISPLAY-ONLY typed fields (provider enum + handle). The
  app never processes payments and never accepts card or bank account numbers.
  Handles are never logged by this module.
* Capacity: bounded integer.
* Location (task 20261010-announcement-location-chat-replies): one optional
  free-text line, trimmed, capped, no control or bidi-override characters.
"""

import re
import unicodedata
from urllib.parse import urlsplit

MAX_LINKS = 5
MAX_LINK_URL_LENGTH = 500
MAX_LINK_LABEL_LENGTH = 60
MAX_GALLERY_IMAGES = 6
MAX_GALLERY_KEY_LENGTH = 300
MAX_PAYMENT_HANDLES = 4
MAX_HANDLE_LENGTH = 64
MIN_CAPACITY = 1
MAX_CAPACITY = 9999
MAX_LOCATION_LENGTH = 120

PAYMENT_PROVIDERS = frozenset({"venmo", "cashapp", "paypal", "zelle"})

_CONTROL_OR_SPACE = re.compile(r"[\s\x00-\x1f\x7f]")
_VENMO_RE = re.compile(r"@?[A-Za-z0-9_-]{5,30}")
_CASHAPP_RE = re.compile(r"\$?[A-Za-z][A-Za-z0-9]{0,19}")
_PAYPAL_ME_RE = re.compile(r"[A-Za-z0-9]{1,20}")
_EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+")
_PHONE_SEPARATORS = re.compile(r"[\s().-]")


def _luhn_ok(digits: str) -> bool:
    total = 0
    for i, ch in enumerate(reversed(digits)):
        d = int(ch)
        if i % 2 == 1:
            d = d * 2 - 9 if d * 2 > 9 else d * 2
        total += d
    return total % 10 == 0


def looks_like_card_or_account_number(value: str) -> bool:
    """True when the digits in ``value`` (separators of any kind ignored)
    number 13 or more, or form a Luhn-valid 12-19 digit run. A 10/11 digit
    phone number passes."""
    digits = re.sub(r"\D", "", value)
    return len(digits) >= 13 or (12 <= len(digits) <= 19 and _luhn_ok(digits))


def normalize_links(value) -> list[dict]:
    """``None`` / ``[]`` -> ``[]``. Items are ``{"url": str, "label": str|None}``."""
    if value is None:
        return []
    if not isinstance(value, list):
        raise ValueError("links must be a list")
    if len(value) > MAX_LINKS:
        raise ValueError(f"At most {MAX_LINKS} links")
    out: list[dict] = []
    seen: set[str] = set()
    for item in value:
        if not isinstance(item, dict) or set(item) - {"url", "label"}:
            raise ValueError("Each link needs a url and an optional label")
        url = item.get("url")
        if not isinstance(url, str):
            raise ValueError("Link url must be text")
        url = url.strip()
        if not url or len(url) > MAX_LINK_URL_LENGTH:
            raise ValueError(f"Link url must be 1 to {MAX_LINK_URL_LENGTH} characters")
        if _CONTROL_OR_SPACE.search(url):
            raise ValueError("Link url can't contain spaces or control characters")
        try:
            parts = urlsplit(url)
            host = parts.hostname
            parts.port  # noqa: B018 - raises ValueError on a bad port
        except ValueError:
            raise ValueError("Link url is not valid")
        if parts.scheme.lower() not in ("http", "https"):
            raise ValueError("Links must start with http:// or https://")
        if not host or "." not in host or "@" in parts.netloc:
            raise ValueError("Link url is not valid")
        url = parts.scheme.lower() + url[len(parts.scheme):]
        if url.lower() in seen:
            continue
        seen.add(url.lower())
        label = item.get("label")
        if label is not None:
            if not isinstance(label, str):
                raise ValueError("Link label must be text")
            label = label.strip()
            if len(label) > MAX_LINK_LABEL_LENGTH:
                raise ValueError(f"Link label must be {MAX_LINK_LABEL_LENGTH} characters or fewer")
            if _CONTROL_OR_SPACE.search(label.replace(" ", "")):
                raise ValueError("Link label can't contain control characters")
            label = label or None
        out.append({"url": url, "label": label})
    return out


def normalize_gallery_keys(value, key_ok) -> list[str]:
    """``key_ok(key) -> bool`` proves a key belongs to this group's prefix.
    Order is preserved, duplicates dropped, count capped."""
    if value is None:
        return []
    if not isinstance(value, list):
        raise ValueError("gallery_keys must be a list")
    if len(value) > MAX_GALLERY_IMAGES:
        raise ValueError(f"At most {MAX_GALLERY_IMAGES} gallery images")
    out: list[str] = []
    for key in value:
        if not isinstance(key, str) or not key or len(key) > MAX_GALLERY_KEY_LENGTH or not key_ok(key):
            raise ValueError("Invalid gallery image reference")
        if key not in out:
            out.append(key)
    return out


def _normalize_handle(provider: str, handle: str) -> str:
    if looks_like_card_or_account_number(handle):
        raise ValueError("Payment handles can't contain card or account numbers")
    if provider == "venmo":
        if not _VENMO_RE.fullmatch(handle) or handle.lstrip("@").isdigit():
            raise ValueError("Enter a valid Venmo username")
        return "@" + handle.lstrip("@")
    if provider == "cashapp":
        if not _CASHAPP_RE.fullmatch(handle):
            raise ValueError("Enter a valid Cash App $cashtag")
        return "$" + handle.lstrip("$")
    if provider == "paypal":
        if _EMAIL_RE.fullmatch(handle):
            return handle.lower()
        if _PAYPAL_ME_RE.fullmatch(handle) and not handle.isdigit():
            return handle
        raise ValueError("Enter a valid PayPal.me name or email")
    # zelle: email or a plain US phone number (digits only after cleanup).
    if _EMAIL_RE.fullmatch(handle):
        return handle.lower()
    digits = _PHONE_SEPARATORS.sub("", handle.removeprefix("+"))
    if digits.isdigit() and (len(digits) == 10 or (len(digits) == 11 and digits.startswith("1"))):
        return digits[-10:]
    raise ValueError("Enter a valid Zelle email or phone number")


def normalize_payment_handles(value) -> list[dict]:
    """``None`` / ``[]`` -> ``[]``. Items are ``{"provider": enum, "handle": str}``,
    one per provider."""
    if value is None:
        return []
    if not isinstance(value, list):
        raise ValueError("payment_handles must be a list")
    if len(value) > MAX_PAYMENT_HANDLES:
        raise ValueError(f"At most {MAX_PAYMENT_HANDLES} payment handles")
    out: list[dict] = []
    seen: set[str] = set()
    for item in value:
        if not isinstance(item, dict) or set(item) != {"provider", "handle"}:
            raise ValueError("Each payment handle needs a provider and a handle")
        provider, handle = item["provider"], item["handle"]
        if not isinstance(provider, str) or provider not in PAYMENT_PROVIDERS:
            raise ValueError("Unsupported payment provider")
        if not isinstance(handle, str):
            raise ValueError("Payment handle must be text")
        handle = handle.strip()
        if not handle or len(handle) > MAX_HANDLE_LENGTH:
            raise ValueError(f"Payment handle must be 1 to {MAX_HANDLE_LENGTH} characters")
        if _CONTROL_OR_SPACE.search(handle.replace(" ", "")):
            raise ValueError("Payment handle can't contain control characters")
        if provider in seen:
            raise ValueError("One handle per payment provider")
        seen.add(provider)
        out.append({"provider": provider, "handle": _normalize_handle(provider, handle)})
    return out


def normalize_capacity(value) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError("capacity must be a whole number")
    if not MIN_CAPACITY <= value <= MAX_CAPACITY:
        raise ValueError(f"capacity must be between {MIN_CAPACITY} and {MAX_CAPACITY}")
    return value


# Bidirectional overrides/isolates can visually reverse the text around them.
_BIDI_CONTROLS = frozenset("\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069")


def normalize_location(value) -> str | None:
    """``None`` / blank -> ``None`` (clears). Otherwise the trimmed text.

    Rejected, never repaired: non-text, over ``MAX_LOCATION_LENGTH`` characters,
    or any control (including newline/tab) or bidi-override character."""
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError("location must be text")
    value = value.strip()
    if not value:
        return None
    if len(value) > MAX_LOCATION_LENGTH:
        raise ValueError(f"location must be {MAX_LOCATION_LENGTH} characters or fewer")
    if any(unicodedata.category(ch) == "Cc" or ch in _BIDI_CONTROLS for ch in value):
        raise ValueError("location can't contain control characters")
    return value
