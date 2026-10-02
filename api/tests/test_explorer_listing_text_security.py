"""Security review pass 1 (explorer listings, step 8): text filters.

Pure unit checks of ``listing_content`` (no database, no HTTP):
  * youth-term filter cannot be bypassed with zero-width characters, full-width
    letters, combining marks or common leetspeak (the stored text is unchanged);
  * reference-style and shortcut Markdown images are refused (an image would be a
    tracking pixel on a public page; media arrive as their own block type later);
  * city and region reject digits (no street address or phone number in a field
    that is not re-reviewed after approval) but keep real place names.
Run: cd api && ../.venv/bin/python tests/test_explorer_listing_text_security.py
"""
import _pathfix  # noqa: F401

from backend.interactions.listing_content import ListingError, normalise
from backend.interactions.listings_config import get_listings_config

PASSED = FAILED = 0


def check(label, ok, detail=""):
    global PASSED, FAILED
    if ok:
        PASSED += 1
        print(f"  OK   {label}")
    else:
        FAILED += 1
        print(f"  FAIL {label}  {detail}")


def code(data):
    try:
        normalise(get_listings_config(), data)
    except ListingError as e:
        return e.code
    return None


def main():
    print("youth terms: normalisation bypasses")
    cfg = get_listings_config()
    check("plain 'teens' rejected", code({"summary": "A group for teens"}) == "youth_not_supported")
    check("zero-width space inside the word rejected", code({"summary": "A group for te​en"}) == "youth_not_supported")
    check("zero-width joiner inside the word rejected", code({"title": "Yo‍uth night"}) == "youth_not_supported")
    check("full-width letters rejected", code({"summary": "ｔｅｅｎｓ welcome"}) == "youth_not_supported")
    check("combining marks rejected", code({"summary": "te̲e̲n̲s"}) == "youth_not_supported")
    check("leetspeak 't33ns' rejected", code({"summary": "t33ns welcome"}) == "youth_not_supported")
    check("leetspeak 'y0uth' rejected", code({"title": "y0uth group"}) == "youth_not_supported")
    check("description text bypass rejected",
          code({"description_blocks": [{"type": "text", "text": "Open to k1ds and adults"}]}) == "youth_not_supported")
    check("numeric range term still rejected", code({"summary": "ages 13-17"}) == "youth_not_supported")
    check("ordinary adult text accepted", code({"title": "Tuesday Bible Study", "summary": "Room 3 at 5pm, all adults"}) is None)
    check("'nineteen' is not a youth term", code({"summary": "We meet at nineteen hundred hours"}) is None)
    check("accented place text accepted", code({"summary": "Café meetup"}) is None)
    stored = normalise(cfg, {"summary": "Café meetup"})["summary"]
    check("stored text is not altered by the matching form", stored == "Café meetup", stored)

    print("markdown images")
    check("reference-style image refused",
          code({"description_blocks": [{"type": "text", "text": "![pic][r]\n\n[r]: https://example.com/p.png"}]}) == "media_not_supported")
    check("shortcut image refused",
          code({"description_blocks": [{"type": "text", "text": "![r]\n\n[r]: https://example.com/p.png"}]}) == "media_not_supported")
    check("inline image still refused",
          code({"description_blocks": [{"type": "text", "text": "![x](https://example.com/p.png)"}]}) == "media_not_supported")
    check("a normal https link is still fine",
          code({"description_blocks": [{"type": "text", "text": "See [our church](https://example.com/about) for more."}]}) is None)
    check("exclamation followed by space then a link is fine",
          code({"description_blocks": [{"type": "text", "text": "Welcome! [Our site](https://example.com)"}]}) is None)

    print("city / region")
    for good in ("Austin", "St. Louis", "Winston-Salem", "Coeur d'Alene", "São Paulo", "Washington, D.C.", "Île-de-France"):
        check(f"place accepted: {good}", code({"city": good}) is None and code({"region": good}) is None, good)
    for bad in ("123 Main St", "Austin 78701", "Call 555-0100", "1 Church Way", "R00m"):
        check(f"place with digits refused: {bad}", code({"city": bad}) == "invalid_place" and code({"region": bad}) == "invalid_place", bad)
    check("empty city clears", normalise(cfg, {"city": ""})["city"] is None)

    print(f"\nRESULT: {PASSED} passed, {FAILED} failed")
    print("STATUS:", "ALL PASS" if not FAILED else "FAILURES")
    raise SystemExit(1 if FAILED else 0)


if __name__ == "__main__":
    main()
