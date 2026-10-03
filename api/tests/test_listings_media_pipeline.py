"""Tests for task 20261002-explorer-listing-media, step 2 (testing): the image
pipeline (listings_media.process_image / fetch_for_processing / confirm_slot) and the
S3 outbox discipline of ListingMediaManager.confirm, against STUBBED S3.

Properties proved (each would catch a regression of the behaviour it names):
  1. Pillow imports cleanly and can decode/encode JPEG, PNG and WebP.
  2. Magic bytes must agree with the declared type; SVG, GIF, HEIC, AVIF, HTML and
     animated PNG/WebP are rejected; empty and over-size input is rejected.
  3. Polyglots: a JPEG/PNG with a ZIP, PDF, HTML or GIF payload appended, or a
     <script> in a JPEG comment / PNG text chunk, comes out with none of those bytes
     and as a clean single image.
  4. Metadata: input EXIF with GPS, an ICC profile and PNG text chunks are present in
     the input and absent from the stored bytes; EXIF orientation is applied.
  5. Limits are enforced from the header BEFORE any pixel decode: a 6001 px side, a
     pixel count over max_pixels and a 60000x60000 decompression-bomb header are all
     rejected with Image.Image.load never called; a DecompressionBombWarning from
     Pillow becomes a rejection, not a 500. Large images are downscaled to 2000 px.
  6. Bounded read: fetch_for_processing never reads more than max+1 bytes, rejects a
     wrong stored Content-Type, maps a missing key to 404 and S3 trouble to 503.
  7. Outbox: the ORIGINAL key is enqueued in pending_s3_deletes on success and on
     every failure after the ownership proof (bad image, wrong type, oversize, missing
     object, S3 get/put failure, DB write failure); a foreign key is enqueued never;
     a derivative stored but not recorded is queued too; delete_object is never
     called on S3 by any of it, and no module in the feature calls it at all.
  8. Replaying confirm for the same original returns the same item, no second row.
  9. confirm_slot caps concurrent decodes (429 busy when the slots are taken).

Scratch DB only (port 55432 asserted first); stubbed S3 only; no AWS.
Run with: cd api && ../.venv/bin/python tests/test_listings_media_pipeline.py
"""
import _pathfix  # noqa: F401

import ast
import dataclasses
import io
import os
import struct
import zlib

from _lm_common import (
    API_DIR, check, finish, require_scratch_db, install_stub_s3, jpeg_bytes, png_bytes, webp_bytes,
    noisy_jpeg, exif_with_gps, has_gps, make_user, make_group, app_client, create_listing, stage_upload, confirm,
    outbox_keys, purge_outbox, cleanup, catch_logs, q, base, hdr, reset_limits, raises_listing_error, snapshot_flags,
    restore_flags, set_flag_sql,
)
from PIL import Image
from backend.interactions import listings_media as lm
from backend.interactions import listings_media_config as lmc
from backend.interactions.listing_content import ListingError
from backend.interactions.listings_media_service import ListingMediaManager

CFG = lmc.get_media_config()


def reject(raw, mime, cfg=None):
    return raises_listing_error(lm.process_image, raw, mime, cfg)


def decode(data):
    im = Image.open(io.BytesIO(data))
    im.load()
    return im


def png_with_header_size(w, h):
    data = bytearray(png_bytes(8, 8))
    body = struct.pack(">II", w, h) + bytes(data[16 + 8:16 + 13])
    crc = zlib.crc32(b"IHDR" + body) & 0xFFFFFFFF
    data[16:16 + 13] = body
    data[16 + 13:16 + 17] = struct.pack(">I", crc)
    return bytes(data)


def test_import_and_formats():
    print("Pillow import and formats")
    import PIL
    import PIL.features as features
    check("Pillow imports and reports a version", bool(PIL.__version__), PIL.__version__)
    check("Pillow has JPEG and WebP codecs", features.check("jpg") and features.check("webp"))
    for mime, raw in (("image/jpeg", jpeg_bytes()), ("image/png", png_bytes()), ("image/webp", webp_bytes())):
        out = lm.process_image(raw, mime)
        im = decode(out.data)
        check(f"{mime} round-trips", out.mime == mime and im.size == (out.width, out.height) == (64, 32), (im.size, out.width))
    check("HEIC/AVIF decoders are not installed (no pillow-heif)", "pillow_heif" not in __import__("sys").modules)


def test_type_rejections():
    print("type and magic-byte rejections")
    jpg, png, webp = jpeg_bytes(), png_bytes(), webp_bytes()
    check("PNG bytes declared as image/jpeg -> invalid_image", getattr(reject(png, "image/jpeg"), "code", None) == "invalid_image")
    check("JPEG bytes declared as image/png -> invalid_image", getattr(reject(jpg, "image/png"), "code", None) == "invalid_image")
    check("JPEG bytes declared as image/webp -> invalid_image", getattr(reject(jpg, "image/webp"), "code", None) == "invalid_image")
    gif = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\xff\xff\xff\x00\x00\x00;"
    svg = b'<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'
    heic = b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic"
    avif = b"\x00\x00\x00\x1cftypavif\x00\x00\x00\x00mif1avif"
    html = b"<html><script>alert(1)</script></html>"
    for label, raw in (("GIF", gif), ("SVG", svg), ("HEIC", heic), ("AVIF", avif), ("HTML", html)):
        for mime in ("image/jpeg", "image/png", "image/webp"):
            e = reject(raw, mime)
            check(f"{label} bytes declared {mime} rejected", e is not None and e.status == 422, e)
    for mime in ("image/gif", "image/svg+xml", "image/heic", "image/heif", "image/avif", "text/html", "", None):
        e = reject(jpg, mime)
        check(f"declared type {mime!r} -> unsupported_media_type", e is not None and e.code == "unsupported_media_type", e)
    check("HTML before a JPEG header (prefix polyglot) -> invalid_image", getattr(reject(b"<html>" + jpg, "image/jpeg"), "code", None) == "invalid_image")
    check("empty input -> image_too_large", getattr(reject(b"", "image/jpeg"), "code", None) == "image_too_large")
    check("a JPEG header with garbage body -> invalid_image", getattr(reject(jpg[:20] + os.urandom(500), "image/jpeg"), "code", None) == "invalid_image")
    check("truncated PNG -> invalid_image", getattr(reject(png[:40], "image/png"), "code", None) == "invalid_image")
    check("random bytes with a PNG signature -> invalid_image", getattr(reject(b"\x89PNG\r\n\x1a\n" + os.urandom(300), "image/png"), "code", None) == "invalid_image")
    # animated
    frames = [Image.new("RGB", (20, 20), c) for c in ((255, 0, 0), (0, 255, 0), (0, 0, 255))]
    out = io.BytesIO()
    frames[0].save(out, format="PNG", save_all=True, append_images=frames[1:], duration=50, loop=0)
    check("animated PNG (APNG) -> invalid_image", getattr(reject(out.getvalue(), "image/png"), "code", None) == "invalid_image")
    out = io.BytesIO()
    frames[0].save(out, format="WEBP", save_all=True, append_images=frames[1:], duration=50, loop=0)
    check("animated WebP -> invalid_image", getattr(reject(out.getvalue(), "image/webp"), "code", None) == "invalid_image")
    out = io.BytesIO()
    frames[0].save(out, format="GIF", save_all=True, append_images=frames[1:], duration=50, loop=0)
    check("animated GIF declared as PNG -> rejected", reject(out.getvalue(), "image/png") is not None)
    # size
    big = jpg + b"\x00" * (CFG.max_upload_bytes + 1 - len(jpg))
    check("bytes over image_max_upload_mb -> image_too_large", getattr(reject(big, "image/jpeg"), "code", None) == "image_too_large")


def test_polyglots():
    print("polyglot payloads are neutralised")
    payloads = {"ZIP": b"PK\x03\x04" + b"\x00" * 40 + b"PK\x01\x02", "PDF": b"%PDF-1.7\n1 0 obj<<>>endobj\n%%EOF",
                "HTML": b"<html><body><script>alert(document.cookie)</script></body></html>", "GIF": b"GIF89a" + b"\x01\x00\x01\x00\x00\x00\x00;",
                "PHP": b"<?php system($_GET['c']); ?>", "ELF": b"\x7fELF" + b"\x00" * 30}
    markers = {"ZIP": b"PK\x03\x04", "PDF": b"%PDF", "HTML": b"<script", "GIF": b"GIF89a", "PHP": b"<?php", "ELF": b"\x7fELF"}
    for mime, maker in (("image/jpeg", jpeg_bytes), ("image/png", png_bytes), ("image/webp", webp_bytes)):
        for name, payload in payloads.items():
            raw = maker() + payload
            try:
                out = lm.process_image(raw, mime)
            except ListingError as e:
                check(f"{name} appended to {mime}: rejected ({e.code})", e.status == 422)
                continue
            im = decode(out.data)
            check(f"{name} appended to {mime}: payload absent from stored bytes", markers[name] not in out.data and payload not in out.data)
            check(f"{name} appended to {mime}: stored bytes are one clean {mime}", Image.MIME[im.format] == mime and getattr(im, "n_frames", 1) == 1)
    # payload inside metadata segments
    from PIL.PngImagePlugin import PngInfo
    com = bytearray(jpeg_bytes())
    seg = b"<script>alert(1)</script>"
    com[2:2] = b"\xff\xfe" + (len(seg) + 2).to_bytes(2, "big") + seg   # COM segment after SOI
    out = lm.process_image(bytes(com), "image/jpeg")
    check("script in a JPEG COM segment is dropped", b"<script" not in out.data)
    out = lm.process_image(png_bytes(text={"Comment": "<script>alert(1)</script>", "Author": "secret"}), "image/png")
    check("script / text in PNG tEXt chunks is dropped", b"<script" not in out.data and b"tEXt" not in out.data and b"secret" not in out.data)
    # trailing bytes after JPEG EOI never survive
    out = lm.process_image(jpeg_bytes() + b"TRAILER-SECRET" * 50, "image/jpeg")
    check("bytes after the JPEG EOI marker do not survive", b"TRAILER-SECRET" not in out.data and out.data.endswith(b"\xff\xd9"))
    out = lm.process_image(png_bytes() + b"TRAILER-SECRET" * 50, "image/png")
    check("bytes after PNG IEND do not survive", b"TRAILER-SECRET" not in out.data and out.data.rstrip().endswith(b"IEND\xaeB`\x82"))


def test_metadata_and_orientation():
    print("metadata stripped, orientation applied")
    raw = jpeg_bytes(exif=exif_with_gps(), icc=b"\x00" * 128)
    check("fixture sanity: input carries GPS EXIF and an ICC profile", has_gps(raw) and b"ICC_PROFILE" in raw and b"SecretCam" in raw)
    out = lm.process_image(raw, "image/jpeg")
    check("stored JPEG has no GPS", not has_gps(out.data))
    check("stored JPEG has no Exif block, camera make or ICC profile", b"Exif" not in out.data and b"SecretCam" not in out.data and b"ICC_PROFILE" not in out.data)
    im = decode(out.data)
    check("stored JPEG getexif() is empty", len(im.getexif()) == 0 and not im.info.get("icc_profile"))
    # PNG text
    out = lm.process_image(png_bytes(text={"GPS": "37.77,-122.41", "Software": "SecretCam"}), "image/png")
    check("stored PNG carries no text chunks", b"SecretCam" not in out.data and b"37.77" not in out.data and not decode(out.data).info.get("GPS"))
    # orientation 6 = rotate 90 CW on display: 64x32 stored -> 32x64 displayed
    raw = jpeg_bytes(64, 32, exif=exif_with_gps(orientation=6))
    out = lm.process_image(raw, "image/jpeg")
    check("EXIF orientation 6 is applied (64x32 -> 32x64)", (out.width, out.height) == (32, 64), (out.width, out.height))
    im = decode(out.data)
    check("... and the orientation tag is gone so viewers do not rotate twice", im.getexif().get(0x0112) in (None, 1) and im.size == (32, 64))
    raw = jpeg_bytes(64, 32, exif=exif_with_gps(orientation=3))
    out = lm.process_image(raw, "image/jpeg")
    check("EXIF orientation 3 keeps dimensions", (out.width, out.height) == (64, 32))
    # downscale and mode handling
    out = lm.process_image(jpeg_bytes(3000, 1500), "image/jpeg")
    check("a 3000x1500 image is downscaled to output_max_side_px", max(out.width, out.height) == CFG.output_max_side_px == 2000 and (out.width, out.height) == (2000, 1000), (out.width, out.height))
    rgba = io.BytesIO()
    Image.new("RGBA", (30, 30), (255, 0, 0, 60)).save(rgba, format="PNG")
    out = lm.process_image(rgba.getvalue(), "image/png")
    check("PNG alpha is preserved", decode(out.data).mode == "RGBA")
    pal = io.BytesIO()
    Image.new("P", (30, 30)).save(pal, format="PNG")
    check("palette PNG is accepted", lm.process_image(pal.getvalue(), "image/png").width == 30)
    cmyk = io.BytesIO()
    Image.new("CMYK", (30, 30)).save(cmyk, format="JPEG")
    out = lm.process_image(cmyk.getvalue(), "image/jpeg")
    check("CMYK JPEG is converted to RGB", decode(out.data).mode == "RGB")


def test_limits_before_decode():
    print("pixel and size limits are enforced from the header, before decode")
    calls = []
    fx = {"j6001": jpeg_bytes(6001, 10), "p6001": png_bytes(10, 6001), "bomb": png_with_header_size(60000, 60000),
          "j2000": jpeg_bytes(2000, 1000), "j1000": jpeg_bytes(1000, 900)}
    real_load = Image.Image.load

    def spy(self, *a, **k):
        calls.append(1)
        return real_load(self, *a, **k)
    Image.Image.load = spy
    try:
        e = reject(fx["j6001"], "image/jpeg")
        check("side 6001 px -> image_too_large", e is not None and e.code == "image_too_large", e)
        check("... without decoding pixels", not calls, len(calls))
        e = reject(fx["p6001"], "image/png")
        check("height 6001 px (PNG) -> image_too_large and no decode", e is not None and e.code == "image_too_large" and not calls)
        e = reject(fx["bomb"], "image/png")
        check("60000x60000 decompression-bomb header -> image_too_large", e is not None and e.code == "image_too_large", e)
        check("... without decoding pixels", not calls, len(calls))
        small_cfg = dataclasses.replace(CFG, max_pixels=1_000_000)
        e = reject(fx["j2000"], "image/jpeg", small_cfg)
        check("pixel count over max_pixels (2 MP vs 1 MP cap) -> image_too_large and no decode", e is not None and e.code == "image_too_large" and not calls, (e, len(calls)))
        out = lm.process_image(fx["j1000"], "image/jpeg", small_cfg)
        check("just under max_pixels is accepted", out.width == 1000 and calls)
    finally:
        Image.Image.load = real_load
    lm.process_image(jpeg_bytes(), "image/jpeg")
    check("Pillow MAX_IMAGE_PIXELS is pinned to the configured cap after processing", Image.MAX_IMAGE_PIXELS == CFG.max_pixels, Image.MAX_IMAGE_PIXELS)
    # a DecompressionBombWarning raised by Pillow itself must be a rejection
    import warnings
    real_open = Image.open

    def bomb_open(*a, **k):
        warnings.warn("bomb", Image.DecompressionBombWarning)
        return real_open(*a, **k)
    Image.open = bomb_open
    try:
        e = reject(jpeg_bytes(), "image/jpeg")
    finally:
        Image.open = real_open
    check("a DecompressionBombWarning from Pillow -> image_too_large (promoted to an error)", e is not None and e.code == "image_too_large", e)
    def bomb_err(*a, **k):
        raise Image.DecompressionBombError("bomb")
    Image.open = bomb_err
    try:
        e = reject(jpeg_bytes(), "image/jpeg")
    finally:
        Image.open = real_open
    check("a DecompressionBombError -> image_too_large", e is not None and e.code == "image_too_large", e)
    def boom(*a, **k):
        raise MemoryError("x")
    Image.open = boom
    try:
        e = reject(jpeg_bytes(), "image/jpeg")
    finally:
        Image.open = real_open
    check("an unexpected decoder exception is a 422 rejection, never a 500", e is not None and e.status == 422, e)


def test_fetch_and_slots(stub):
    print("bounded read, error mapping, concurrency slots")

    class Body:
        def __init__(self, n):
            self.n, self.asked = n, []

        def read(self, size=-1):
            self.asked.append(size)
            return b"\xff\xd8\xff" + b"0" * (min(size, self.n) - 3 if size >= 0 else self.n)
    key = "listings/AbCdEfGh12/00000000-0000-4000-8000-000000000001.jpg"
    body = Body(CFG.max_upload_bytes * 3)
    stub.objects[key] = (b"x" * 2048, "image/jpeg")
    stub.get_object_orig = stub.get_object
    stub.get_object = lambda Bucket, Key: {"Body": body}
    e = raises_listing_error(lm.fetch_for_processing, key, "image/jpeg")
    check("a body larger than the cap is rejected after a bounded read", e is not None and e.code == "image_too_large", e)
    check("read() was asked for at most max+1 bytes (never unbounded)", body.asked and all(0 < s <= CFG.max_upload_bytes + 1 for s in body.asked), body.asked)
    stub.get_object = stub.get_object_orig
    stub.objects[key] = (b"x" * 2048, "text/html")
    e = raises_listing_error(lm.fetch_for_processing, key, "image/jpeg")
    check("stored Content-Type that differs from the declared one -> invalid_image", e is not None and e.code == "invalid_image", e)
    stub.objects[key] = (b"x" * (CFG.max_upload_bytes + 1), "image/jpeg")
    e = raises_listing_error(lm.fetch_for_processing, key, "image/jpeg")
    check("head_object over the cap -> image_too_large before any get", e is not None and e.code == "image_too_large" and not stub.called("get_object"), e)
    stub.objects.pop(key)
    e = raises_listing_error(lm.fetch_for_processing, key, "image/jpeg")
    check("missing object -> uniform 404", e is not None and e.status == 404 and e.code == "not_found", e)
    stub.objects[key] = (b"x" * 2048, "image/jpeg")
    stub.fail_get = True
    e = raises_listing_error(lm.fetch_for_processing, key, "image/jpeg")
    stub.fail_get = False
    check("S3 get failure -> 503 media_unavailable", e is not None and e.status == 503, e)
    stub.objects.pop(key)

    # slots
    tight = dataclasses.replace(CFG, confirm_wait_seconds=1)
    lm._slots = None
    a, b = lm.confirm_slot(tight), lm.confirm_slot(tight)
    a.__enter__(), b.__enter__()
    try:
        e = raises_listing_error(lambda: lm.confirm_slot(tight).__enter__())
        check(f"a third concurrent decode (limit {tight.confirm_concurrency}) -> 429 busy", e is not None and e.status == 429 and e.code == "busy", e)
    finally:
        a.__exit__(None, None, None)
        b.__exit__(None, None, None)
    with lm.confirm_slot(tight):
        pass
    check("slots are released (a later confirm gets one)", True)


def test_outbox_discipline(cli, stub):
    print("S3 outbox: original key enqueued on every path after the ownership proof")
    uid = make_user()
    gid = make_group(uid)
    pid = create_listing(cli, uid, gid)
    stranger_uid = make_user()
    sgid = make_group(stranger_uid)
    spid = create_listing(cli, stranger_uid, sgid)
    purge_outbox(f"listings/{pid}/")
    purge_outbox(f"listings/{spid}/")

    # success
    orig = stage_upload(stub, pid, jpeg_bytes(80, 40, exif=exif_with_gps()), "image/jpeg")
    r = confirm(cli, uid, gid, "photo", orig)
    check("success: 200 with a media item", r.status_code == 200 and r.json()["kind"] == "photo" and r.json()["width"] == 80, r.text)
    item = r.json()
    derived = q("SELECT object_key FROM group_listing_media WHERE _id = %s", (item["media_id"],))[0][0]
    check("success: derivative key is a NEW key (never the original)", derived != orig and lm.parse_key(pid, derived) is not None, derived)
    check("success: the derivative object is stored, GPS-free and a valid JPEG", derived in stub.objects and not has_gps(stub.objects[derived][0]) and decode(stub.objects[derived][0]).format == "JPEG")
    check("success: the stored derivative has the right content type", stub.objects[derived][1] == "image/jpeg")
    check("success: the original (with GPS) is queued in the outbox", orig in outbox_keys())
    check("success: the derivative is NOT queued", derived not in outbox_keys())
    check("success: the response URL is the derivative's, never the original's", derived.split("/")[-1] in item["url"] and orig.split("/")[-1] not in item["url"], item["url"])
    check("success: listing's photo_key points at the derivative", q("SELECT photo_key FROM group_listings WHERE group_id = %s", (gid,))[0][0] == derived)

    # replay
    r2 = confirm(cli, uid, gid, "photo", orig)
    check("replay of the same original -> same item, 200", r2.status_code == 200 and r2.json()["media_id"] == item["media_id"], r2.text)
    check("replay: still exactly one media row", q("SELECT count(*) FROM group_listing_media gl JOIN group_listings l ON l._id = gl.listing_id WHERE l.group_id = %s", (gid,))[0][0] == 1)
    # a stored derivative is never a source
    r3 = confirm(cli, uid, gid, "photo", derived)
    check("confirming the derivative's own key -> uniform 404", r3.status_code == 404 and r3.json() == {"detail": {"code": "not_found", "message": "Not found"}}, r3.text)

    failures = {}

    def attempt(label, stage_data, ctype, mime_for_key, expect_status, expect_code=None, kind="photo", before=None, after=None):
        k = stage_upload(stub, pid, stage_data, mime_for_key) if stage_data is not None else lm.build_key(pid, mime_for_key)
        if stage_data is not None:
            stub.objects[k] = (stage_data, ctype)
        if before:
            before()
        try:
            r = confirm(cli, uid, gid, kind, k, alt="alt text")
        finally:
            if after:
                after()
        ok = r.status_code == expect_status and (expect_code is None or r.json()["detail"]["code"] == expect_code)
        check(f"{label}: {expect_status}{'/' + expect_code if expect_code else ''}", ok, (r.status_code, r.text))
        check(f"{label}: original key is queued in the outbox", k in outbox_keys(), k)
        return k

    attempt("PNG bytes behind a .jpg key", png_bytes(), "image/jpeg", "image/jpeg", 422, "invalid_image")
    attempt("HTML bytes behind a .jpg key", b"<html><script>1</script></html>" * 50, "image/jpeg", "image/jpeg", 422, "invalid_image")
    attempt("stored Content-Type text/html", jpeg_bytes(), "text/html", "image/jpeg", 422, "invalid_image")
    attempt("oversize object", b"\xff\xd8\xff" + b"0" * (CFG.max_upload_bytes + 10), "image/jpeg", "image/jpeg", 422, "image_too_large")
    attempt("6001 px side", jpeg_bytes(6001, 8), "image/jpeg", "image/jpeg", 422, "image_too_large")
    attempt("animated WebP", None, None, "image/webp", 404, "not_found")  # object missing -> 404, still queued (ownership already proven)
    fr = [Image.new("RGB", (20, 20), c) for c in ((255, 0, 0), (0, 255, 0))]
    o = io.BytesIO()
    fr[0].save(o, format="WEBP", save_all=True, append_images=fr[1:], duration=40, loop=0)
    attempt("animated WebP object", o.getvalue(), "image/webp", "image/webp", 422, "invalid_image")

    def get_fail():
        stub.fail_get = True

    def get_ok():
        stub.fail_get = False
    attempt("S3 read failure", jpeg_bytes(), "image/jpeg", "image/jpeg", 503, "media_unavailable", before=get_fail, after=get_ok)

    def put_fail():
        stub.fail_put = True

    def put_ok():
        stub.fail_put = False
    attempt("S3 write failure", jpeg_bytes(), "image/jpeg", "image/jpeg", 503, "media_unavailable", before=put_fail, after=put_ok)

    # DB write failure after the derivative was stored: both keys must be queued
    real_record = ListingMediaManager._record

    def failing_record(self, *a, **k):
        raise ListingError(409, "media_conflict", "forced")
    ListingMediaManager._record = failing_record
    try:
        k = stage_upload(stub, pid, jpeg_bytes(50, 50), "image/jpeg")
        r = confirm(cli, uid, gid, "banner", k, alt="a banner")
    finally:
        ListingMediaManager._record = real_record
    dk = lm.derived_key(pid, k, "image/jpeg")
    check("DB write failure after store: 409", r.status_code == 409, r.text)
    check("DB write failure: original AND the stored-but-unreferenced derivative are queued", {k, dk} <= outbox_keys(), (k in outbox_keys(), dk in outbox_keys()))

    # key of another listing / garbage: ownership not proven -> never queued, never read
    foreign = stage_upload(stub, spid, jpeg_bytes(), "image/jpeg")
    n_get = len(stub.called("get_object"))
    r = confirm(cli, uid, gid, "photo", foreign)
    check("another listing's key -> uniform 404", r.status_code == 404 and r.json() == {"detail": {"code": "not_found", "message": "Not found"}}, r.text)
    check("another listing's key is NOT queued for deletion (not ours to delete)", foreign not in outbox_keys())
    check("another listing's key was never read from S3", len(stub.called("get_object")) == n_get and foreign not in stub.called("head_object"))
    for bad in (f"listings/{pid}/../{spid}/x.jpg", "attachments/secret.jpg", f"listings/{pid}/%2e%2e/x.jpg", "x" * 400):
        r = confirm(cli, uid, gid, "photo", bad)
        check(f"unparseable key {bad[:30]!r} -> 404/422 and never queued", r.status_code in (404, 422) and bad not in outbox_keys(), (r.status_code, r.text[:80]))

    check("no S3 delete_object and no copy_object call was made by any confirm path", not stub.called("delete_object") and not stub.called("copy_object"), stub.calls[-3:])
    purge_outbox(f"listings/{pid}/")
    purge_outbox(f"listings/{spid}/")


def test_static_no_direct_delete():
    print("static: no module of the feature deletes from S3 directly")
    for name in ("listings_media.py", "listings_media_service.py", "listings_media_sweeper.py"):
        src = open(os.path.join(API_DIR, "backend", "interactions", name)).read()
        tree = ast.parse(src)
        bad = [ast.unparse(n.func) for n in ast.walk(tree) if isinstance(n, ast.Call)
               and isinstance(n.func, ast.Attribute) and n.func.attr in ("delete_object", "delete_objects", "copy_object")]
        check(f"{name} has no delete_object / copy_object call", not bad, bad)
    src = open(os.path.join(API_DIR, "backend", "interactions", "listings_media.py")).read()
    check("process_image never saves the decoded image object with its own info (metadata reset)", "clean.info = {}" in src)


def main():
    require_scratch_db()
    stub = install_stub_s3()
    saved = snapshot_flags()
    cli = app_client()
    try:
        set_flag_sql("explorer_publish", "on")
        test_import_and_formats()
        test_type_rejections()
        test_polyglots()
        test_metadata_and_orientation()
        test_limits_before_decode()
        test_fetch_and_slots(stub)
        test_static_no_direct_delete()
        test_outbox_discipline(cli, stub)
    finally:
        restore_flags(saved)
        cleanup()
    finish()


if __name__ == "__main__":
    main()
