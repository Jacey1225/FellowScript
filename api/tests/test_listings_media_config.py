"""Tests for task 20261002-explorer-listing-media, step 2 (testing): the explorer.json
``media`` section loader (listings_media_config) fails fast.

Properties proved:
  1. The shipped config loads, is video_enabled=false, and every value is within the
     hard ceilings.
  2. Removing ANY required key fails with ConfigSectionError (no implicit defaults).
  3. An unknown key, a wrong type (str/bool/float for an int, non-bool video_enabled),
     a missing section, a missing file and malformed JSON all fail.
  4. Every cross-field and ceiling rule: max_pixels > 36 MP, max_side_px > 6000, upload
     size > 20 MB, concurrency > 4, output side > max side, quality outside 1..100,
     fewer than 3 images, cache >= ttl, min upload >= max upload, a non-positive
     number, unsupported / duplicate MIME, unsupported video provider, bad
     rate_limits keys or strings.
  5. A failure does not poison the cache: validate_media_config re-reads the file, and
     startup_checks calls validate_media_config so a bad file refuses to boot.

Scratch DB only (port 55432 asserted first). Config files are temp copies; the real
explorer.json is never modified.
Run with: cd api && ../.venv/bin/python tests/test_listings_media_config.py
"""
import _pathfix  # noqa: F401

import copy
import json
import os
import tempfile

from _lm_common import API_DIR, check, finish, require_scratch_db
from backend.config_loader import ConfigSectionError
from backend.interactions import listings_media_config as lmc

REAL_PATH = lmc.CONFIG_PATH
REAL = json.load(open(REAL_PATH))
GOOD = REAL["media"]
TMP = tempfile.mkdtemp(prefix="lm_cfg_")


def write(media, section="media", raw=None):
    doc = copy.deepcopy(REAL)
    doc.pop("media", None)
    if media is not None:
        doc[section] = media
    path = os.path.join(TMP, "explorer.json")
    with open(path, "w") as f:
        f.write(raw if raw is not None else json.dumps(doc))
    return path


def load_with(media, **kw):
    lmc.CONFIG_PATH = write(media, **kw)
    lmc.reset_for_tests()
    try:
        return lmc.validate_media_config()
    finally:
        lmc.CONFIG_PATH = REAL_PATH
        lmc.reset_for_tests()


def fails(media, **kw):
    try:
        load_with(media, **kw)
    except ConfigSectionError as e:
        return str(e)
    except Exception as e:  # noqa: BLE001
        return f"WRONG EXCEPTION {type(e).__name__}: {e}"
    return None


def mutated(**changes):
    m = copy.deepcopy(GOOD)
    for k, v in changes.items():
        m[k] = v
    return m


def expect_fail(label, media, needle=None, **kw):
    err = fails(media, **kw)
    check(label, err is not None and not err.startswith("WRONG") and (needle is None or needle in err), err)


def main():
    require_scratch_db()
    print("shipped config")
    cfg = lmc.get_media_config()
    check("shipped media section loads", cfg is not None)
    check("video_enabled is false by default", cfg.video_enabled is False)
    check("allowed_mime is JPEG/PNG/WebP only (no GIF/SVG/HEIC)", set(cfg.allowed_mime) == {"image/jpeg", "image/png", "image/webp"}, cfg.allowed_mime)
    check("limits within ceilings", cfg.max_pixels <= 36_000_000 and cfg.max_side_px <= 6000 and cfg.image_max_upload_mb <= 20 and cfg.confirm_concurrency <= 4)
    check("get_media_config is cached", lmc.get_media_config() is cfg)
    check("a valid temp copy of the same values loads", fails(GOOD) is None)

    print("every required key is required")
    for key in list(GOOD):
        m = copy.deepcopy(GOOD)
        del m[key]
        expect_fail(f"missing '{key}' fails fast", m, key)
    for rk in lmc.RATE_LIMIT_KEYS:
        m = copy.deepcopy(GOOD)
        del m["rate_limits"][rk]
        expect_fail(f"missing rate_limits.{rk} fails", m)

    print("unknown keys, wrong types, bad structure")
    expect_fail("unknown key fails", mutated(surprise=1), "surprise")
    for key in lmc._INT_KEYS:
        expect_fail(f"{key}: string instead of int", mutated(**{key: "5"}), key)
    expect_fail("an int key given as bool is refused (bool is not int)", mutated(max_pixels=True), "max_pixels")
    expect_fail("an int key given as float is refused", mutated(max_pixels=1.5e6), "max_pixels")
    expect_fail("video_enabled as a string is refused", mutated(video_enabled="false"), "video_enabled")
    expect_fail("video_enabled as 0 is refused", mutated(video_enabled=0), "video_enabled")
    expect_fail("allowed_mime as a string is refused", mutated(allowed_mime="image/jpeg"))
    expect_fail("rate_limits as a list is refused", mutated(rate_limits=[]))
    expect_fail("media section missing", None, "media")
    expect_fail("media section is not an object", "oops")
    expect_fail("malformed JSON", GOOD, raw="{not json")
    expect_fail("top-level list", GOOD, raw="[]")
    lmc.CONFIG_PATH = os.path.join(TMP, "does-not-exist.json")
    lmc.reset_for_tests()
    try:
        lmc.validate_media_config()
        check("missing file fails", False, "loaded")
    except ConfigSectionError as e:
        check("missing file fails", "not found" in str(e), e)
    finally:
        lmc.CONFIG_PATH = REAL_PATH
        lmc.reset_for_tests()

    print("ceilings and cross-field rules")
    expect_fail("max_pixels over 36 MP", mutated(max_pixels=36_000_001), "max_pixels")
    expect_fail("max_side_px over 6000", mutated(max_side_px=6001), "max_side_px")
    expect_fail("image_max_upload_mb over 20", mutated(image_max_upload_mb=21), "image_max_upload_mb")
    expect_fail("confirm_concurrency over 4", mutated(confirm_concurrency=5), "confirm_concurrency")
    expect_fail("output_max_side_px over max_side_px", mutated(output_max_side_px=6001), "output_max_side_px")
    expect_fail("jpeg_quality 0", mutated(jpeg_quality=0), "jpeg_quality")
    expect_fail("jpeg_quality 101", mutated(jpeg_quality=101), "jpeg_quality")
    expect_fail("webp_quality 101", mutated(webp_quality=101), "webp_quality")
    expect_fail("max_images_per_listing below 3", mutated(max_images_per_listing=2), "max_images_per_listing")
    expect_fail("download_url_cache_seconds >= ttl", mutated(download_url_cache_seconds=3600), "download_url_cache_seconds")
    expect_fail("image_min_upload_bytes >= max upload", mutated(image_min_upload_bytes=8 * 1024 * 1024), "image_min_upload_bytes")
    expect_fail("zero orphan_grace_hours", mutated(orphan_grace_hours=0), "orphan_grace_hours")
    expect_fail("negative sweep cap", mutated(sweep_max_keys_per_run=-1), "sweep_max_keys_per_run")
    expect_fail("empty allowed_mime", mutated(allowed_mime=[]), "allowed_mime")
    expect_fail("image/gif in allowed_mime", mutated(allowed_mime=["image/jpeg", "image/gif"]), "allowed_mime")
    expect_fail("image/svg+xml in allowed_mime", mutated(allowed_mime=["image/svg+xml"]), "allowed_mime")
    expect_fail("image/heic in allowed_mime", mutated(allowed_mime=["image/heic"]), "allowed_mime")
    expect_fail("duplicate allowed_mime", mutated(allowed_mime=["image/png", "image/png"]), "allowed_mime")
    expect_fail("unsupported video provider", mutated(video_providers=["youtube", "evil"]), "video_providers")
    expect_fail("empty video_providers", mutated(video_providers=[]), "video_providers")
    expect_fail("rate_limits with an extra key", mutated(rate_limits={**GOOD["rate_limits"], "extra": "1/minute"}), "rate_limits")
    expect_fail("rate_limits string that does not parse", mutated(rate_limits={**GOOD["rate_limits"], "confirm": "lots"}), "confirm")
    expect_fail("rate_limits non-string", mutated(rate_limits={**GOOD["rate_limits"], "confirm": 5}), "confirm")
    check("edge values at the ceilings are accepted", fails(mutated(max_pixels=36_000_000, max_side_px=6000, image_max_upload_mb=20,
                                                                    confirm_concurrency=4, jpeg_quality=100, max_images_per_listing=3)) is None)

    print("failures do not poison the cache; startup wiring")
    lmc.CONFIG_PATH = write(mutated(max_pixels=36_000_001))
    lmc.reset_for_tests()
    try:
        lmc.get_media_config()
        check("get_media_config raises for a bad file (never defaults)", False)
    except ConfigSectionError:
        check("get_media_config raises for a bad file (never defaults)", True)
    lmc.CONFIG_PATH = write(GOOD)
    check("after the file is fixed the next load succeeds (no cached failure)", lmc.get_media_config() is not None)
    lmc.CONFIG_PATH = REAL_PATH
    lmc.reset_for_tests()
    src = open(os.path.join(API_DIR, "backend", "startup_checks.py")).read()
    check("startup_checks imports and calls validate_media_config", "import validate_media_config" in src and "validate_media_config()" in src)
    src = open(os.path.join(API_DIR, "backend", "interactions", "listings_media_config.py")).read()
    check("no default values are baked into the loader (every key required)", "setdefault" not in src and ".get(" not in src)
    finish()


if __name__ == "__main__":
    main()
