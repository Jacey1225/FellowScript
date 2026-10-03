"""Tests for task 20261002-explorer-listing-media, step 2 (testing): listing media
key building and ownership proofs (listings_media.build_key / parse_key / derived_key).

Properties proved (each would catch a regression of the behaviour it names):
  1. build_key returns exactly listings/{public_id}/{uuid}{ext}; the extension comes
     only from the validated MIME type; an unsupported MIME or malformed public id
     raises instead of building a key.
  2. parse_key fails closed (None) for: another listing's key, another prefix, '..'
     and encoded traversal, backslash, upper-case / odd / double extensions, trailing
     characters, non-uuid names, nested paths, over-long keys, non-strings.
  3. derived_key is deterministic per original (idempotent confirm) and different
     between originals; mime_for_key follows the extension.
  4. The sweeper's candidate filter never matches foreign, probe or odd keys.

Scratch DB only (port 55432 asserted first). No S3.
Run with: cd api && ../.venv/bin/python tests/test_listings_media_keys.py
"""
import _pathfix  # noqa: F401

import re
import uuid

from _lm_common import check, finish, require_scratch_db
from backend.interactions import listings_media as lm
from backend.interactions import listings_media_sweeper as sweeper

PID = "AbCdEfGh12"
OTHER = "ZyXwVuTs98"


def main():
    require_scratch_db()
    print("build_key")
    for mime, ext in (("image/jpeg", ".jpg"), ("image/png", ".png"), ("image/webp", ".webp")):
        k = lm.build_key(PID, mime)
        check(f"build_key {mime} shape", re.fullmatch(rf"listings/{PID}/[0-9a-f-]{{36}}\{ext}", k) is not None, k)
        check(f"build_key {mime} round-trips through parse_key", lm.parse_key(PID, k) == (mime, ext), k)
    check("two keys never collide", lm.build_key(PID, "image/png") != lm.build_key(PID, "image/png"))
    for bad_mime in ("image/gif", "image/svg+xml", "image/heic", "text/html", "", None):
        try:
            lm.build_key(PID, bad_mime)
            check(f"build_key refuses mime {bad_mime!r}", False, "built a key")
        except (ValueError, TypeError):
            check(f"build_key refuses mime {bad_mime!r}", True)
    for bad_pid in ("short", "has/slash12", "../../etcab", "AbCdEfGh1!", "", None, "AbCdEfGh123"):
        try:
            lm.build_key(bad_pid, "image/png")
            check(f"build_key refuses public id {bad_pid!r}", False, "built a key")
        except (ValueError, TypeError):
            check(f"build_key refuses public id {bad_pid!r}", True)

    print("parse_key fails closed")
    u = str(uuid.uuid4())
    good = f"listings/{PID}/{u}.jpg"
    check("a well-formed key of this listing parses", lm.parse_key(PID, good) == ("image/jpeg", ".jpg"))
    cases = {
        "other listing's key": f"listings/{OTHER}/{u}.jpg",
        "other prefix": f"attachments/{PID}/{u}.jpg",
        "group-photos prefix": f"group-photos/{PID}/{u}.jpg",
        "no prefix": f"{PID}/{u}.jpg",
        "leading slash": f"/listings/{PID}/{u}.jpg",
        "dotdot segment": f"listings/{PID}/../{OTHER}/{u}.jpg",
        "dotdot in name": f"listings/{PID}/{u}..jpg",
        "dotdot to root": f"listings/{PID}/../../etc/passwd",
        "url-encoded traversal": f"listings/{PID}/%2e%2e/{u}.jpg",
        "encoded slash": f"listings/{PID}%2f{u}.jpg",
        "double-encoded dot": f"listings/{PID}/%252e%252e/{u}.jpg",
        "backslash": f"listings\\{PID}\\{u}.jpg",
        "upper-case extension": f"listings/{PID}/{u}.JPG",
        "mixed-case extension": f"listings/{PID}/{u}.Png",
        "odd extension": f"listings/{PID}/{u}.gif",
        "svg extension": f"listings/{PID}/{u}.svg",
        "heic extension": f"listings/{PID}/{u}.heic",
        "double extension": f"listings/{PID}/{u}.jpg.php",
        "double extension reversed": f"listings/{PID}/{u}.php.jpg",
        "no extension": f"listings/{PID}/{u}",
        "trailing char": f"listings/{PID}/{u}.jpg ",
        "trailing newline": f"listings/{PID}/{u}.jpg\n",
        "non-uuid name": f"listings/{PID}/photo.jpg",
        "upper-case uuid": f"listings/{PID}/{u.upper()}.jpg",
        "nested path": f"listings/{PID}/sub/{u}.jpg",
        "_probe key": f"listings/_probe/{u}.png",
        "null byte": f"listings/{PID}/{u}.jpg\x00.png",
        "over-long key": "listings/" + "a" * 300,
    }
    for label, key in cases.items():
        check(f"parse_key rejects {label}", lm.parse_key(PID, key) is None, key[:80])
    for junk in (None, 123, b"listings/x", ["listings"], {}):
        check(f"parse_key rejects non-string {type(junk).__name__}", lm.parse_key(PID, junk) is None)
    for bad_pid in (None, "", "short", f"{PID}/", "../..", OTHER + "x"):
        check(f"parse_key rejects invalid public id {bad_pid!r}", lm.parse_key(bad_pid, good) is None)

    print("already-derived key as a confirm source")
    orig = lm.build_key(PID, "image/jpeg")
    d = lm.derived_key(PID, orig, "image/jpeg")
    check("derived_key is itself a valid listing key (so confirm must refuse it by DB lookup, not by shape)",
          lm.parse_key(PID, d) == ("image/jpeg", ".jpg"), d)
    check("derived_key is deterministic", d == lm.derived_key(PID, orig, "image/jpeg"))
    check("derived_key differs per original", d != lm.derived_key(PID, lm.build_key(PID, "image/jpeg"), "image/jpeg"))
    check("derived_key differs from its original", d != orig)
    check("derived_key differs per listing", lm.parse_key(OTHER, d) is None)

    print("mime_for_key / public_listing_key")
    check("mime_for_key by extension", lm.mime_for_key("listings/x/y.webp") == "image/webp" and lm.mime_for_key("x.png") == "image/png")
    check("mime_for_key unknown extension -> None", lm.mime_for_key("listings/x/y.gif") is None and lm.mime_for_key(None) is None)
    check("public_listing_key keeps this listing's key", lm.public_listing_key(PID, good) == good)
    check("public_listing_key drops a foreign or tampered key",
          lm.public_listing_key(PID, f"listings/{OTHER}/{u}.jpg") is None
          and lm.public_listing_key(PID, "attachments/x/y.jpg") is None and lm.public_listing_key(PID, None) is None)
    check("media_url refuses non-listing, traversal and odd-extension keys without signing",
          lm.media_url("attachments/a.jpg") is None and lm.media_url(f"listings/{PID}/../x.jpg") is None
          and lm.media_url(f"listings/{PID}/{u}.gif") is None and lm.media_url(None) is None)

    print("sweeper candidate filter")
    check("sweeper considers only own-shaped keys",
          sweeper._is_listing_media_key(good)
          and not sweeper._is_listing_media_key(f"listings/_probe/{u}.png")
          and not sweeper._is_listing_media_key(f"listings/{PID}/../{u}.jpg")
          and not sweeper._is_listing_media_key(f"listings/{PID}/{u}.gif")
          and not sweeper._is_listing_media_key(f"group-photos/g/{u}.jpg")
          and not sweeper._is_listing_media_key(f"listings/{PID}/x/{u}.jpg"))
    finish()


if __name__ == "__main__":
    main()
