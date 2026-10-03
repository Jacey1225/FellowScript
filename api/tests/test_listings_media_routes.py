"""Tests for task 20261002-explorer-listing-media, step 2 (testing): the owner media
routes and the description media blocks, through HTTP, against STUBBED S3.

Properties proved (each would catch a regression of the behaviour it names):
  1. upload-url: presigned POST whose policy pins the exact Content-Type and
     content-length-range from config, key listings/{public_id}/{uuid}{ext} with a
     server-derived extension; GIF/SVG/HEIC and unknown kinds are 422.
  2. Owner-only and IDOR: stranger, non-creator member and a missing group get ONE
     identical 404 on every media route; another listing's key and another listing's
     media_id never reach a row or the outbox; a suspended owner is refused.
  3. Flag gating: explorer_publish off -> 404 (same as missing), canary -> only the
     canary user, on -> works; terms gate -> 403; rate limit -> 429.
  4. Caps: image count (photo + banner + description images <= max_images_per_listing),
     description image cap, and per-listing byte cap are 409 media_limit; replacing a
     photo or banner does not count against the cap and queues the old derivative.
  5. Alt text: required for banner and description images, plain text only, bounded.
  6. Video: a video block is rejected while video_enabled=false, /options drops the
     video block type, a stored video block is never emitted publicly; it works only
     when the flag is flipped (proving the gate is the switch).
  7. Description image blocks: hold {type, media_id, alt} only, must reference a ready
     image of THIS listing, cannot be deleted while in use, public output carries a
     server-issued URL and no storage key or media_id.
  8. Use-current-group-photo: re-encoded through the pipeline (EXIF/GPS dropped), never
     copy_object, the group's own photo key is never queued for deletion.
  9. Re-queue rule (R3-m7): adding, replacing or removing a banner, photo or
     description image on a published listing calls requeue_for_review(.., 'media') and
     returns it to pending_review; an idempotent re-confirm does not.
 10. Owner view and public view expose photo_url / banner_url / banner_alt / media.

Scratch DB only (port 55432 asserted first); stubbed S3 only; flags restored.
Run with: cd api && ../.venv/bin/python tests/test_listings_media_routes.py
"""
import _pathfix  # noqa: F401

import base64
import dataclasses
import json
import re
import uuid

from _lm_common import (
    NOT_FOUND, check, finish, require_scratch_db, install_stub_s3, jpeg_bytes, png_bytes, webp_bytes, exif_with_gps,
    has_gps, make_user, make_group, app_client, create_listing, stage_upload, confirm, outbox_keys, purge_outbox,
    cleanup, q, base, hdr, reset_limits, snapshot_flags, restore_flags, set_flag_sql, listing_status, publish, approve,
    noisy_jpeg,
)
from backend.interactions import flags, listings, listings_media as lm, listings_media_config as lmc

CFG = lmc.get_media_config()
CONTENT_TYPE_HDR = "content-type"


def post_json(cli, url, body, uid):
    reset_limits()
    return cli.post(url, json=body, headers=hdr(uid))


def upload_url(cli, uid, gid, kind="photo", ctype="image/jpeg", hh=None):
    reset_limits()
    return cli.post(base(uid, gid) + "/media/upload-url", json={"kind": kind, "content_type": ctype}, headers=hh or hdr(uid))


def add(cli, stub, uid, gid, pid, kind, alt="alt text", data=None, mime="image/jpeg"):
    key = stage_upload(stub, pid, data or jpeg_bytes(60, 40), mime)
    r = confirm(cli, uid, gid, kind, key, alt=alt if kind != "photo" else None)
    assert r.status_code == 200, (kind, r.status_code, r.text)
    return key, r.json()


def put(cli, uid, gid, body):
    reset_limits()
    return cli.put(base(uid, gid), json=body, headers=hdr(uid))


def test_upload_url(cli):
    print("upload-url policy")
    uid = make_user()
    gid = make_group(uid)
    pid = create_listing(cli, uid, gid)
    for mime, ext in (("image/jpeg", ".jpg"), ("image/png", ".png"), ("image/webp", ".webp")):
        r = upload_url(cli, uid, gid, "photo", mime)
        check(f"{mime}: 200", r.status_code == 200, r.text)
        d = r.json()
        check(f"{mime}: key is listings/{{public_id}}/{{uuid}}{ext}", re.fullmatch(rf"listings/{pid}/[0-9a-f-]{{36}}\{ext}", d["object_key"]) is not None, d["object_key"])
        policy = json.loads(base64.b64decode(d["fields"]["policy"]))
        conds = policy["conditions"]
        check(f"{mime}: policy pins the exact Content-Type", {"Content-Type": mime} in conds or ["eq", "$Content-Type", mime] in conds, conds)
        rng = [c for c in conds if isinstance(c, list) and c and c[0] == "content-length-range"]
        check(f"{mime}: content-length-range comes from config", rng and rng[0][1] == CFG.image_min_upload_bytes and rng[0][2] == CFG.max_upload_bytes, rng)
        check(f"{mime}: policy pins the key", d["fields"].get("key") == d["object_key"] or {"key": d["object_key"]} in conds, d["fields"].keys())
        check(f"{mime}: no wildcard key condition", not [c for c in conds if isinstance(c, list) and c[0] == "starts-with" and c[1] == "$key"])
        check(f"{mime}: expires_in / max_bytes from config", d["expires_in"] == CFG.upload_url_ttl_seconds and d["max_bytes"] == CFG.max_upload_bytes)
    for label, ctype in (("GIF", "image/gif"), ("SVG", "image/svg+xml"), ("HEIC", "image/heic"), ("HTML", "text/html"), ("empty", "")):
        r = upload_url(cli, uid, gid, "photo", ctype)
        check(f"{label} content type -> 422 unsupported_media_type", r.status_code == 422 and r.json()["detail"]["code"] == "unsupported_media_type", (r.status_code, r.text))
    r = upload_url(cli, uid, gid, "avatar", "image/jpeg")
    check("unknown kind -> 422", r.status_code == 422, r.text)
    r = upload_url(cli, uid, gid, "video", "image/jpeg")
    check("kind 'video' -> 422 (inert)", r.status_code == 422, r.text)
    reset_limits()
    r = cli.post(base(uid, gid) + "/media/upload-url", json={"kind": "photo", "content_type": "image/jpeg", "key": "listings/x/y.jpg"}, headers=hdr(uid))
    check("a client-supplied key field is refused (extra=forbid)", r.status_code == 422, r.text)
    g2 = make_group(uid, title="No listing yet")
    r = upload_url(cli, uid, g2)
    check("no listing yet -> 409 listing_required", r.status_code == 409 and r.json()["detail"]["code"] == "listing_required", r.text)
    n = q("SELECT count(*) FROM group_listing_media")[0][0]
    check("upload-url writes no media row", q("SELECT count(*) FROM group_listing_media gm JOIN group_listings l ON l._id = gm.listing_id WHERE l.group_id = %s", (gid,))[0][0] == 0)


def test_owner_only_idor(cli, stub):
    print("owner-only, IDOR, suspended owner")
    owner, member, stranger = make_user(), make_user(), make_user()
    gid = make_group(owner, [member])
    pid = create_listing(cli, owner, gid)
    other_owner = make_user()
    ogid = make_group(other_owner)
    opid = create_listing(cli, other_owner, ogid)
    purge_outbox(f"listings/{pid}/")
    purge_outbox(f"listings/{opid}/")
    _okey, oitem = add(cli, stub, other_owner, ogid, opid, "image")
    missing = str(uuid.uuid4())
    key = stage_upload(stub, pid, jpeg_bytes(), "image/jpeg")
    bodies = []
    for who, uid in (("stranger", stranger), ("non-creator member", member)):
        hh = hdr(uid)
        for label, call in (
            ("upload-url", lambda uid=uid, hh=hh: upload_url(cli, uid, gid, hh=hh)),
            ("confirm", lambda uid=uid, hh=hh: confirm(cli, uid, gid, "photo", key, hh=hh)),
            ("group-photo", lambda uid=uid, hh=hh: (reset_limits(), cli.post(base(uid, gid) + "/media/group-photo", headers=hh))[1]),
            ("delete", lambda uid=uid, hh=hh: (reset_limits(), cli.delete(base(uid, gid) + f"/media/{oitem['media_id']}", headers=hh))[1]),
        ):
            r = call()
            bodies.append(r.text)
            check(f"{who}: {label} -> 404", r.status_code == 404 and r.json() == NOT_FOUND, (r.status_code, r.text))
    # a missing group answers identically
    reset_limits()
    r = cli.post(base(owner, missing) + "/media/upload-url", json={"kind": "photo", "content_type": "image/jpeg"}, headers=hdr(owner))
    check("a missing group answers the same 404 body", r.status_code == 404 and r.json() == NOT_FOUND, r.text)
    check("the key staged for a stranger's confirm was not queued and no row exists",
          key not in outbox_keys() and q("SELECT count(*) FROM group_listing_media gm JOIN group_listings l ON l._id = gm.listing_id WHERE l.group_id = %s", (gid,))[0][0] == 0)
    # IDOR with the owner's own session
    foreign = stage_upload(stub, opid, jpeg_bytes(), "image/jpeg")
    r = confirm(cli, owner, gid, "photo", foreign)
    check("owner confirming ANOTHER listing's key -> uniform 404", r.status_code == 404 and r.json() == NOT_FOUND, r.text)
    check("... nothing stored, foreign object not queued", foreign not in outbox_keys() and not q("SELECT 1 FROM group_listings WHERE group_id = %s AND photo_key IS NOT NULL", (gid,)))
    reset_limits()
    r = cli.delete(base(owner, gid) + f"/media/{oitem['media_id']}", headers=hdr(owner))
    check("owner deleting ANOTHER listing's media_id -> uniform 404", r.status_code == 404 and r.json() == NOT_FOUND, r.text)
    check("... the other listing's row survives", q("SELECT count(*) FROM group_listing_media WHERE _id = %s", (oitem["media_id"],))[0][0] == 1)
    for bad in ("not-a-uuid", "../x", str(uuid.uuid4())):
        reset_limits()
        r = cli.delete(base(owner, gid) + f"/media/{bad}", headers=hdr(owner))
        check(f"delete unknown media id {bad!r} -> 404", r.status_code == 404 and (r.json() == NOT_FOUND or bad == "../x"), (r.status_code, r.text))
    # path user != session user (require_match)
    reset_limits()
    r = cli.post(base(owner, gid) + "/media/upload-url", json={"kind": "photo", "content_type": "image/jpeg"}, headers=hdr(stranger))
    check("path user_id that is not the session user is refused", r.status_code in (401, 403, 404), r.status_code)
    reset_limits()
    r = cli.post(base(owner, gid) + "/media/upload-url", json={"kind": "photo", "content_type": "image/jpeg"})
    check("no session -> 401/403", r.status_code in (401, 403), r.status_code)
    # suspended owner
    q("UPDATE users SET suspended_at = NOW() WHERE _id = %s", (owner,), fetch=False)
    r = upload_url(cli, owner, gid)
    check("suspended owner: upload-url -> uniform 404", r.status_code in (404, 401, 403), (r.status_code, r.text))
    sk = stage_upload(stub, pid, jpeg_bytes(), "image/jpeg")
    r = confirm(cli, owner, gid, "photo", sk)
    check("suspended owner: confirm refused and nothing stored", r.status_code in (404, 401, 403)
          and q("SELECT count(*) FROM group_listing_media gm JOIN group_listings l ON l._id = gm.listing_id WHERE l.group_id = %s", (gid,))[0][0] == 0, (r.status_code, r.text))
    q("UPDATE users SET suspended_at = NULL WHERE _id = %s", (owner,), fetch=False)
    # owner who left the group
    q("UPDATE groups SET users = %s WHERE _id = %s", ([member], gid), fetch=False)
    r = upload_url(cli, owner, gid)
    check("creator no longer a member -> uniform 404", r.status_code == 404 and r.json() == NOT_FOUND, r.text)
    q("UPDATE groups SET users = %s WHERE _id = %s", ([owner, member], gid), fetch=False)
    purge_outbox(f"listings/{pid}/")
    purge_outbox(f"listings/{opid}/")


def test_flags_terms_rate(cli, stub):
    print("flag gating, terms gate, rate limit")
    uid, other = make_user(), make_user()
    gid = make_group(uid)
    pid = create_listing(cli, uid, gid)
    key = stage_upload(stub, pid, jpeg_bytes(), "image/jpeg")
    set_flag_sql("explorer_publish", "off")
    for label, r in (("upload-url", upload_url(cli, uid, gid)), ("confirm", confirm(cli, uid, gid, "photo", key)),
                     ("group-photo", (reset_limits(), cli.post(base(uid, gid) + "/media/group-photo", headers=hdr(uid)))[1]),
                     ("delete", (reset_limits(), cli.delete(base(uid, gid) + f"/media/{uuid.uuid4()}", headers=hdr(uid)))[1])):
        check(f"flag off: {label} -> uniform 404", r.status_code == 404 and r.json() == NOT_FOUND, (r.status_code, r.text))
    check("flag off: nothing stored", not q("SELECT 1 FROM group_listings WHERE group_id = %s AND photo_key IS NOT NULL", (gid,)))
    set_flag_sql("explorer_publish", "canary", [other])
    r = upload_url(cli, uid, gid)
    check("canary: a user NOT in the canary list -> 404", r.status_code == 404 and r.json() == NOT_FOUND, r.text)
    cg = make_group(other)
    create_flag_off = None
    set_flag_sql("explorer_publish", "on")
    create_listing(cli, other, cg)
    set_flag_sql("explorer_publish", "canary", [other])
    r = upload_url(cli, other, cg)
    check("canary: the canary user -> 200", r.status_code == 200, (r.status_code, r.text))
    set_flag_sql("explorer_publish", "on")
    r = upload_url(cli, uid, gid)
    check("flag on: 200", r.status_code == 200, r.text)
    r = cli.get(f"/explorer/{uid}/options", headers=hdr(uid))
    check("flag on: /options carries media limits and no 'video' block type", r.status_code == 200
          and r.json()["media"]["video_enabled"] is False and "video" not in r.json()["block_types"]
          and r.json()["media"]["max_images_per_listing"] == CFG.max_images_per_listing, r.text[:300])
    # terms gate
    q("UPDATE users SET terms_version = '1999-01-01' WHERE _id = %s", (uid,), fetch=False)
    r = upload_url(cli, uid, gid)
    check("stale terms: upload-url -> 403 terms_reaccept_required", r.status_code == 403 and r.json()["detail"]["code"] == "terms_reaccept_required", (r.status_code, r.text))
    r = confirm(cli, uid, gid, "photo", key)
    check("stale terms: confirm -> 403 and nothing stored", r.status_code == 403 and not q("SELECT 1 FROM group_listings WHERE group_id = %s AND photo_key IS NOT NULL", (gid,)), r.text)
    from schemas.users import CURRENT_TERMS_VERSION
    q("UPDATE users SET terms_version = %s WHERE _id = %s", (CURRENT_TERMS_VERSION, uid), fetch=False)
    # rate limit upload-url: 20/hour per user
    reset_limits()
    codes = [cli.post(base(uid, gid) + "/media/upload-url", json={"kind": "photo", "content_type": "image/jpeg"}, headers=hdr(uid)).status_code for _ in range(24)]
    check("upload-url per-user limit (20/hour) returns 429 and only after the 20th", codes[:20].count(200) == 20 and 429 in codes[20:], codes)
    reset_limits()
    codes = [cli.delete(base(uid, gid) + f"/media/{uuid.uuid4()}", headers=hdr(uid)).status_code for _ in range(64)]
    check("manage limit (60/minute) returns 429", 429 in codes and codes[0] == 404, set(codes))
    reset_limits()
    purge_outbox(f"listings/{pid}/")


def test_caps(cli, stub):
    print("count and byte caps, replacement")
    uid = make_user()
    gid = make_group(uid)
    pid = create_listing(cli, uid, gid)
    purge_outbox(f"listings/{pid}/")
    k1, p1 = add(cli, stub, uid, gid, pid, "photo")
    k2, b1 = add(cli, stub, uid, gid, pid, "banner")
    d_photo1 = q("SELECT object_key FROM group_listing_media WHERE _id = %s", (p1["media_id"],))[0][0]
    check("max_images_per_listing - 2 description images are allowed", CFG.max_description_images == CFG.max_images_per_listing - 2)
    for i in range(CFG.max_description_images):
        add(cli, stub, uid, gid, pid, "image", alt=f"image {i}")
    check("listing is now at the image cap", q("SELECT count(*) FROM group_listing_media gm JOIN group_listings l ON l._id = gm.listing_id WHERE l.group_id = %s", (gid,))[0][0] == CFG.max_images_per_listing)
    key = stage_upload(stub, pid, jpeg_bytes(), "image/jpeg")
    r = confirm(cli, uid, gid, "image", key, alt="one too many")
    check("one more description image -> 409 media_limit", r.status_code == 409 and r.json()["detail"]["code"] == "media_limit", (r.status_code, r.text))
    check("... the refused upload's original is queued for deletion, nothing was stored for it",
          lm.derived_key(pid, key, "image/jpeg") not in stub.objects)
    r = upload_url(cli, uid, gid, "image")
    check("upload-url for another image at the cap -> 409 media_limit (before any upload)", r.status_code == 409 and r.json()["detail"]["code"] == "media_limit", r.text)
    r = upload_url(cli, uid, gid, "photo")
    check("upload-url for a photo REPLACEMENT at the cap is still allowed", r.status_code == 200, r.text)
    # replacement: photo
    n_before = q("SELECT count(*) FROM group_listing_media gm JOIN group_listings l ON l._id = gm.listing_id WHERE l.group_id = %s", (gid,))[0][0]
    k3, p2 = add(cli, stub, uid, gid, pid, "photo", data=jpeg_bytes(70, 70))
    check("replacing the photo at the cap succeeds and keeps the count", q("SELECT count(*) FROM group_listing_media gm JOIN group_listings l ON l._id = gm.listing_id WHERE l.group_id = %s", (gid,))[0][0] == n_before)
    check("the replaced photo's derivative is queued for deletion", d_photo1 in outbox_keys())
    check("the old photo row is gone and photo_key points at the new one", not q("SELECT 1 FROM group_listing_media WHERE _id = %s", (p1["media_id"],))
          and q("SELECT photo_key FROM group_listings WHERE group_id = %s", (gid,))[0][0] == q("SELECT object_key FROM group_listing_media WHERE _id = %s", (p2["media_id"],))[0][0])
    # byte cap
    tiny = dataclasses.replace(CFG, max_bytes_per_listing=sum(r[0] for r in q(
        "SELECT size_bytes FROM group_listing_media gm JOIN group_listings l ON l._id = gm.listing_id WHERE l.group_id = %s", (gid,))) + 10)
    lmc._cached = tiny
    try:
        key = stage_upload(stub, pid, jpeg_bytes(300, 300), "image/jpeg")
        r = confirm(cli, uid, gid, "banner", key, alt="bigger banner")
        # a banner replaces the old banner, so its old bytes are freed; make it larger than that
        key2 = stage_upload(stub, pid, noisy_jpeg(60_000), "image/jpeg")
        r2 = confirm(cli, uid, gid, "banner", key2, alt="much bigger banner")
        check("exceeding max_bytes_per_listing -> 409 media_limit",
              r2.status_code == 409 and r2.json()["detail"]["code"] == "media_limit", (r.status_code, r2.status_code, r2.text))
        check("... no row references it, and both the stored derivative and the original are queued for deletion",
              lm.derived_key(pid, key2, "image/jpeg") in outbox_keys() and key2 in outbox_keys()
              and not q("SELECT 1 FROM group_listing_media WHERE object_key = %s", (lm.derived_key(pid, key2, "image/jpeg"),)))
    finally:
        lmc._cached = CFG
    purge_outbox(f"listings/{pid}/")


def test_alt_and_blocks(cli, stub):
    print("alt text, description image blocks, delete-in-use, video inert")
    uid = make_user()
    gid = make_group(uid)
    pid = create_listing(cli, uid, gid)
    for kind in ("banner", "image"):
        key = stage_upload(stub, pid, jpeg_bytes(), "image/jpeg")
        r = confirm(cli, uid, gid, kind, key)
        check(f"{kind} without alt -> 422 alt_required", r.status_code == 422 and r.json()["detail"]["code"] == "alt_required", (r.status_code, r.text))
        r = confirm(cli, uid, gid, kind, key, alt="   ")
        check(f"{kind} with blank alt -> 422 alt_required", r.status_code == 422 and r.json()["detail"]["code"] == "alt_required", r.text)
        r = confirm(cli, uid, gid, kind, key, alt="<script>alert(1)</script>")
        check(f"{kind} with HTML alt -> 422", r.status_code == 422, r.text)
        r = confirm(cli, uid, gid, kind, key, alt="see https://evil.example.com now")
        check(f"{kind} with a link in alt -> 422", r.status_code == 422, r.text)
        r = confirm(cli, uid, gid, kind, key, alt="x" * (CFG.alt_max_length + 1))
        check(f"{kind} with over-long alt -> 422 too_long", r.status_code == 422 and r.json()["detail"]["code"] == "too_long", r.text)
    check("none of the refused confirms stored a row", q("SELECT count(*) FROM group_listing_media gm JOIN group_listings l ON l._id = gm.listing_id WHERE l.group_id = %s", (gid,))[0][0] == 0)
    key = stage_upload(stub, pid, jpeg_bytes(), "image/jpeg")
    r = confirm(cli, uid, gid, "photo", key)
    check("a photo does not need alt text", r.status_code == 200 and r.json()["alt_text"] is None, r.text)
    kb, banner = add(cli, stub, uid, gid, pid, "banner", alt="Our group at the lake")
    check("banner alt is stored on the listing", q("SELECT banner_alt FROM group_listings WHERE group_id = %s", (gid,))[0][0] == "Our group at the lake")
    ki, img = add(cli, stub, uid, gid, pid, "image", alt="Bible study table")
    mid = img["media_id"]
    # image block validation through PUT
    def blocks(bl):
        return put(cli, uid, gid, {"description_blocks": bl})
    r = blocks([{"type": "text", "text": "Hello"}, {"type": "image", "media_id": mid, "alt": "Bible study table"}])
    check("a valid image block saves", r.status_code == 200, (r.status_code, r.text))
    saved = q("SELECT description_blocks FROM group_listings WHERE group_id = %s", (gid,))[0][0]
    check("stored block is exactly {type, media_id, alt} (no storage key)", saved[1] == {"type": "image", "media_id": mid, "alt": "Bible study table"} and "listings/" not in json.dumps(saved), saved)
    r = blocks([{"type": "image", "media_id": mid}])
    check("image block without an alt field -> 422 invalid_block", r.status_code == 422 and r.json()["detail"]["code"] == "invalid_block", r.text)
    r = blocks([{"type": "image", "media_id": mid, "alt": "  "}])
    check("image block with blank alt -> 422 alt_required", r.status_code == 422 and r.json()["detail"]["code"] == "alt_required", r.text)
    r = blocks([{"type": "image", "media_id": mid, "alt": "<b>x</b>"}])
    check("image block with HTML alt -> 422", r.status_code == 422, r.text)
    r = blocks([{"type": "image", "media_id": mid, "alt": "x", "object_key": "listings/zzz/x.jpg"}])
    check("image block carrying an object_key / extra field -> 422 invalid_block", r.status_code == 422 and r.json()["detail"]["code"] == "invalid_block", r.text)
    r = blocks([{"type": "image", "media_id": "../../etc/passwd", "alt": "x"}])
    check("image block with a non-uuid media_id -> 422", r.status_code == 422, r.text)
    r = blocks([{"type": "image", "media_id": str(uuid.uuid4()), "alt": "x"}])
    check("image block pointing at an unknown media id -> 422 media_not_found", r.status_code == 422 and r.json()["detail"]["code"] == "media_not_found", r.text)
    # another listing's media id
    o2 = make_user()
    g2 = make_group(o2)
    p2 = create_listing(cli, o2, g2)
    _k, other = add(cli, stub, o2, g2, p2, "image")
    r = blocks([{"type": "image", "media_id": other["media_id"], "alt": "stolen"}])
    check("image block pointing at ANOTHER listing's media -> 422 media_not_found", r.status_code == 422 and r.json()["detail"]["code"] == "media_not_found", r.text)
    # the photo row is not an 'image' row
    pr = q("SELECT gm._id::text FROM group_listing_media gm JOIN group_listings l ON l._id = gm.listing_id WHERE l.group_id = %s AND gm.kind = 'photo'", (gid,))[0][0]
    r = blocks([{"type": "image", "media_id": pr, "alt": "photo as block"}])
    check("image block pointing at the photo row (kind != image) -> 422", r.status_code == 422, r.text)
    # delete while in use
    r = blocks([{"type": "image", "media_id": mid, "alt": "Bible study table"}])
    reset_limits()
    d = cli.delete(base(uid, gid) + f"/media/{mid}", headers=hdr(uid))
    check("deleting an image still used by a block -> 409 media_in_use", d.status_code == 409 and d.json()["detail"]["code"] == "media_in_use", (d.status_code, d.text))
    blocks([{"type": "text", "text": "no image now"}])
    purge_outbox(f"listings/{pid}/")
    dk = q("SELECT object_key FROM group_listing_media WHERE _id = %s", (mid,))[0][0]
    reset_limits()
    d = cli.delete(base(uid, gid) + f"/media/{mid}", headers=hdr(uid))
    check("deleting an unused image -> 204", d.status_code == 204, (d.status_code, d.text))
    check("... row gone and its derivative queued (not deleted inline)", not q("SELECT 1 FROM group_listing_media WHERE _id = %s", (mid,)) and dk in outbox_keys() and not stub.called("delete_object"))
    reset_limits()
    d = cli.delete(base(uid, gid) + f"/media/{pr}", headers=hdr(uid))
    check("deleting the photo clears photo_key", d.status_code == 204 and q("SELECT photo_key FROM group_listings WHERE group_id = %s", (gid,))[0][0] is None)
    reset_limits()
    d = cli.delete(base(uid, gid) + f"/media/{banner['media_id']}", headers=hdr(uid))
    check("deleting the banner clears banner_key and banner_alt", d.status_code == 204 and q("SELECT banner_key, banner_alt FROM group_listings WHERE group_id = %s", (gid,))[0] == (None, None))

    # video: inert while video_enabled = false
    video = {"type": "video", "provider": "youtube", "video_id": "dQw4w9WgXcQ", "title": "Welcome"}
    r = blocks([video])
    check("video block -> 422 video_not_enabled while video_enabled=false", r.status_code == 422 and r.json()["detail"]["code"] == "video_not_enabled", (r.status_code, r.text))
    check("video_enabled is false in the shipped config", CFG.video_enabled is False)
    public_out = lm.public_blocks([video, {"type": "text", "text": "t"}], {})
    check("a video block that is already stored is never emitted publicly while disabled", public_out == [{"type": "text", "text": "t"}], public_out)
    enabled = dataclasses.replace(CFG, video_enabled=True)
    lmc._cached = enabled
    try:
        r = blocks([video])
        check("flipping video_enabled=true is the only switch: a valid video block then saves", r.status_code == 200, (r.status_code, r.text))
        for label, bad in (("javascript provider", {**video, "provider": "javascript:alert(1)"}), ("unknown provider", {**video, "provider": "evil"}),
                           ("url instead of id", {**video, "video_id": "https://youtu.be/dQw4w9WgXcQ"}), ("no title", {**video, "title": ""}),
                           ("extra field", {**video, "src": "https://evil"})):
            r = blocks([bad])
            check(f"video validator rejects {label}", r.status_code == 422, (r.status_code, r.text))
        check("public output emits an allowlisted video block when enabled", lm.public_blocks([{**video, "extra": "x"}], {}) == [video])
    finally:
        lmc._cached = CFG
    check("... and is inert again after switching off", lm.public_blocks([video], {}) == [])
    blocks([{"type": "text", "text": "reset"}])
    purge_outbox(f"listings/{pid}/")
    purge_outbox(f"listings/{p2}/")


def test_group_photo(cli, stub):
    print("use current group photo: re-encoded, never copied")
    uid = make_user()
    gid = make_group(uid)
    pid = create_listing(cli, uid, gid)
    purge_outbox(f"listings/{pid}/")
    reset_limits()
    r = cli.post(base(uid, gid) + "/media/group-photo", headers=hdr(uid))
    check("no group photo -> 422 no_group_photo", r.status_code == 422 and r.json()["detail"]["code"] == "no_group_photo", (r.status_code, r.text))
    src = f"group-photos/{gid}/{uuid.uuid4()}.jpg"
    stub.put(src, jpeg_bytes(90, 60, exif=exif_with_gps()), "image/jpeg")
    q("UPDATE groups SET photo_key = %s WHERE _id = %s", (src, gid), fetch=False)
    reset_limits()
    r = cli.post(base(uid, gid) + "/media/group-photo", headers=hdr(uid))
    check("with a group photo -> 200 photo item", r.status_code == 200 and r.json()["kind"] == "photo" and r.json()["width"] == 90, (r.status_code, r.text))
    dk = q("SELECT photo_key FROM group_listings WHERE group_id = %s", (gid,))[0][0]
    check("the listing photo is a NEW listings/ key, not the group-photos key", dk != src and lm.parse_key(pid, dk) is not None, dk)
    check("the source had GPS and the stored copy does not (re-encoded)", has_gps(stub.objects[src][0]) and not has_gps(stub.objects[dk][0]))
    check("copy_object was never used", not stub.called("copy_object"))
    check("the group's own photo is NOT queued for deletion and still exists", src not in outbox_keys() and src in stub.objects)
    reset_limits()
    r2 = cli.post(base(uid, gid) + "/media/group-photo", headers=hdr(uid))
    check("using it again replaces the photo (one photo row) and queues the old derivative", r2.status_code == 200
          and q("SELECT count(*) FROM group_listing_media gm JOIN group_listings l ON l._id = gm.listing_id WHERE l.group_id = %s AND gm.kind = 'photo'", (gid,))[0][0] == 1
          and dk in outbox_keys())
    # tampered photo_key pointing at someone else's / listing key
    q("UPDATE groups SET photo_key = %s WHERE _id = %s", ("group-photos/" + str(uuid.uuid4()) + "/x.jpg", gid), fetch=False)
    reset_limits()
    r = cli.post(base(uid, gid) + "/media/group-photo", headers=hdr(uid))
    check("a photo_key under another group's prefix is refused (no_group_photo)", r.status_code == 422 and r.json()["detail"]["code"] == "no_group_photo", r.text)
    q("UPDATE groups SET photo_key = %s WHERE _id = %s", ("group-photos/" + gid + "/x.gif", gid), fetch=False)
    reset_limits()
    r = cli.post(base(uid, gid) + "/media/group-photo", headers=hdr(uid))
    check("a group photo in an unsupported format -> 422", r.status_code == 422, r.text)
    q("UPDATE groups SET photo_key = NULL WHERE _id = %s", (gid,), fetch=False)
    purge_outbox(f"listings/{pid}/")


def test_requeue_and_views(cli, stub):
    print("re-queue rule (R3-m7) and owner/public views")
    owner = make_user()
    admin = make_user()
    gid = make_group(owner, [make_user()])
    pid = create_listing(cli, owner, gid, {"accepting_requests": True, "title": "Media Requeue"})
    purge_outbox(f"listings/{pid}/")
    publish(cli, owner, gid, admin)
    calls = []
    real = listings.requeue_for_review

    def spy(cur, group_id, reason):
        calls.append((group_id, reason))
        return real(cur, group_id, reason)
    import backend.interactions.listings_media_service as svc
    svc.requeue_for_review = spy
    try:
        def step(label, fn, expect_requeue=True):
            calls.clear()
            res = fn()
            if expect_requeue:
                check(f"{label}: requeue_for_review(cur, group_id, 'media') called", (gid, "media") in calls, calls)
                check(f"{label}: published -> pending_review", listing_status(gid) == "pending_review", listing_status(gid))
                approve(pid, admin)
                check(f"{label}: (re-approved)", listing_status(gid) == "published")
            else:
                check(f"{label}: requeue NOT called and still published", not calls and listing_status(gid) == "published", (calls, listing_status(gid)))
            return res
        ph = step("adding a photo", lambda: add(cli, stub, owner, gid, pid, "photo"))
        bn = step("adding a banner", lambda: add(cli, stub, owner, gid, pid, "banner", alt="banner alt"))
        im = step("adding a description image", lambda: add(cli, stub, owner, gid, pid, "image", alt="image alt"))
        okey = ph[0]

        def replay():
            r = confirm(cli, owner, gid, "photo", okey)
            assert r.status_code == 200 and r.json()["media_id"] == ph[1]["media_id"], r.text
        step("an idempotent re-confirm of the same original", replay, expect_requeue=False)
        step("replacing the photo", lambda: add(cli, stub, owner, gid, pid, "photo", data=jpeg_bytes(33, 33)))
        step("replacing the banner", lambda: add(cli, stub, owner, gid, pid, "banner", alt="new banner alt", data=png_bytes(40, 20), mime="image/png"))
        # description image block add / remove goes through the text-edit re-queue
        calls.clear()
        r = put(cli, owner, gid, {"description_blocks": [{"type": "image", "media_id": im[1]["media_id"], "alt": "image alt"}]})
        check("adding a description image block", r.status_code == 200 and listing_status(gid) == "pending_review", (r.status_code, listing_status(gid), r.text))
        approve(pid, admin)
        r = put(cli, owner, gid, {"description_blocks": [{"type": "image", "media_id": im[1]["media_id"], "alt": "image alt"}]})
        check("re-saving the identical blocks is not a change (stays published)", r.status_code == 200 and listing_status(gid) == "published", listing_status(gid))
        r = put(cli, owner, gid, {"description_blocks": []})
        check("removing the description image block re-queues", r.status_code == 200 and listing_status(gid) == "pending_review", listing_status(gid))
        approve(pid, admin)

        def rm(mid):
            reset_limits()
            r = cli.delete(base(owner, gid) + f"/media/{mid}", headers=hdr(owner))
            assert r.status_code == 204, r.text
        step("removing the description image", lambda: rm(im[1]["media_id"]))
        step("removing the photo", lambda: rm(q("SELECT gm._id::text FROM group_listing_media gm JOIN group_listings l ON l._id = gm.listing_id WHERE l.group_id = %s AND gm.kind = 'photo'", (gid,))[0][0]))
        step("removing the banner", lambda: rm(q("SELECT gm._id::text FROM group_listing_media gm JOIN group_listings l ON l._id = gm.listing_id WHERE l.group_id = %s AND gm.kind = 'banner'", (gid,))[0][0]))
        # a refused confirm (validation failure) must not re-queue
        calls.clear()
        k = stage_upload(stub, pid, png_bytes(), "image/jpeg")
        r = confirm(cli, owner, gid, "photo", k)
        check("a refused confirm does not re-queue", r.status_code == 422 and not calls and listing_status(gid) == "published", (r.status_code, calls))
        # require_approval off -> no re-queue call
    finally:
        svc.requeue_for_review = real

    print("owner and public views")
    _kp, photo = add(cli, stub, owner, gid, pid, "photo")
    approve(pid, admin) if listing_status(gid) == "pending_review" else None
    _kb, banner = add(cli, stub, owner, gid, pid, "banner", alt="Banner for the public")
    approve(pid, admin) if listing_status(gid) == "pending_review" else None
    _ki, image = add(cli, stub, owner, gid, pid, "image", alt="Public image alt")
    approve(pid, admin) if listing_status(gid) == "pending_review" else None
    put(cli, owner, gid, {"description_blocks": [{"type": "text", "text": "Welcome"}, {"type": "image", "media_id": image["media_id"], "alt": "Public image alt"}]})
    approve(pid, admin) if listing_status(gid) == "pending_review" else None
    reset_limits()
    ov = cli.get(base(owner, gid), headers=hdr(owner)).json()
    check("owner view: photo_url, banner_url, banner_alt, media list", ov.get("photo_url") and ov.get("banner_url") and ov.get("banner_alt") == "Banner for the public" and len(ov.get("media", [])) == 3, {k: ov.get(k) for k in ("photo_url", "banner_alt")})
    check("owner view URLs are presigned https GETs for listings/ keys", all(u.startswith("https://") and "X-Amz-Signature" in u and "/listings/" in u for u in (ov["photo_url"], ov["banner_url"])), ov["photo_url"][:80])
    set_flag_sql("explorer_browse", "on")
    from backend import public_guard
    from backend.interactions import listings_config
    public_guard.reset_for_tests()
    listings_config.validate_listings_config()
    reset_limits()
    r = cli.get(f"/explorer/listings/{pid}")
    check("public detail: 200", r.status_code == 200, (r.status_code, r.text[:200]))
    d = r.json()
    check("public detail: photo_url, banner_url, banner_alt", bool(d["photo_url"]) and bool(d["banner_url"]) and d["banner_alt"] == "Banner for the public", d)
    imgs = [b for b in d["description_blocks"] if b["type"] == "image"]
    check("public detail: image block has url/alt/width/height and nothing else", len(imgs) == 1 and set(imgs[0]) == {"type", "url", "alt", "width", "height"} and imgs[0]["alt"] == "Public image alt", imgs)
    raw = r.text
    check("public detail leaks no media_id, object_key, photo_key or banner_key", image["media_id"] not in raw and "object_key" not in raw and "photo_key" not in raw and "banner_key" not in raw)
    check("public detail URLs are signed derivative URLs, never an original upload", all("X-Amz-Signature" in u for u in (d["photo_url"], d["banner_url"], imgs[0]["url"])))
    reset_limits()
    r = cli.get("/explorer/listings", params={"q": "Media Requeue"})
    card = [c for c in r.json().get("listings", []) if c["public_id"] == pid]
    check("public list card carries photo_url", r.status_code == 200 and card and card[0]["photo_url"], r.text[:200])
    # an unpublished listing leaks nothing
    q("UPDATE group_listings SET status = 'unpublished' WHERE group_id = %s", (gid,), fetch=False)
    reset_limits()
    r = cli.get(f"/explorer/listings/{pid}")
    check("a non-public listing's detail (and its media URLs) is a 404", r.status_code == 404, r.status_code)
    purge_outbox(f"listings/{pid}/")


def main():
    require_scratch_db()
    stub = install_stub_s3()
    saved = snapshot_flags()
    cli = app_client()
    try:
        set_flag_sql("explorer_publish", "on")
        test_upload_url(cli)
        test_owner_only_idor(cli, stub)
        test_flags_terms_rate(cli, stub)
        set_flag_sql("explorer_publish", "on")
        test_caps(cli, stub)
        test_alt_and_blocks(cli, stub)
        test_group_photo(cli, stub)
        test_requeue_and_views(cli, stub)
        check("no S3 delete_object / copy_object call was made in this whole run", not stub.called("delete_object") and not stub.called("copy_object"))
    finally:
        lmc._cached = CFG
        restore_flags(saved)
        cleanup()
    finish()


if __name__ == "__main__":
    main()
