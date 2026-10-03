"""Shared helpers for the listing-media test scripts (test_listings_media_*.py).
Not a test itself. Stubbed S3 only: ``install_stub_s3()`` replaces
``attachments._client`` with an in-memory fake, so no AWS call is ever made.
Database work is scratch-only: ``require_scratch_db()`` aborts unless the
server port is 55432 (or 5432 under GITHUB_ACTIONS).
"""
import _pathfix  # noqa: F401

import base64
import io
import json
import logging
import os
import struct
import sys
import uuid
import zlib

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "dummy")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "dummy")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

import boto3  # noqa: E402
from botocore.config import Config  # noqa: E402
from botocore.exceptions import ClientError  # noqa: E402
from PIL import Image  # noqa: E402

from db import DBManager  # noqa: E402
from backend.interactions import attachments, flags  # noqa: E402
from backend.auth.sessions import SessionManager  # noqa: E402
from schemas.users import CURRENT_TERMS_VERSION  # noqa: E402
from _plan_common import grant_paid  # noqa: E402

API_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_DIR = os.path.dirname(API_DIR)
PASSED, FAILED = [], []
USERS, GROUPS = [], []
BUCKET = "lm-test-bucket-stub"
NOT_FOUND = {"detail": {"code": "not_found", "message": "Not found"}}


def check(label, cond, detail=""):
    (PASSED if cond else FAILED).append(label if cond else (label, detail))
    print(f"  {'OK  ' if cond else 'FAIL'} {label}" + ("" if cond else f"  -- {detail}"))


def require_scratch_db():
    d = DBManager()
    try:
        d.cur.execute("SHOW port")
        port = d.cur.fetchone()[0]
    finally:
        d.close()
    ok = port == "55432" or (port == "5432" and os.environ.get("GITHUB_ACTIONS") == "true")
    check("tests run against scratch DB port 55432", ok, port)
    if not ok:
        raise SystemExit("refusing to continue: not the scratch database")


def finish():
    print(f"\n{'=' * 60}")
    if FAILED:
        print(f"RESULT: {len(PASSED)} passed, {len(FAILED)} FAILED")
        for label, detail in FAILED:
            print(f"  X {label} -- {detail}")
        print("STATUS: FAIL")
        raise SystemExit(1)
    print(f"RESULT: {len(PASSED)} passed, 0 failed")
    print("STATUS: ALL PASS")


# -- stub S3 -------------------------------------------------------------------------

class StubS3:
    """In-memory S3. Presigning is delegated to a real botocore client (pure local
    signing with dummy credentials, never a network call). ``delete_object`` and
    ``copy_object`` are recorded so tests can assert nobody called them."""

    def __init__(self):
        self.objects = {}   # key -> (bytes, content_type)
        self.calls = []     # (method, key)
        self.fail_put = False
        self.fail_get = False
        self._real = boto3.client(
            "s3", region_name="us-east-1",
            config=Config(s3={"addressing_style": "virtual"}, signature_version="s3v4"),
        )

    def put(self, key, data, ctype):
        self.objects[key] = (data, ctype)

    @staticmethod
    def _err(code, op):
        return ClientError({"Error": {"Code": code, "Message": code}}, op)

    def head_object(self, Bucket, Key):
        self.calls.append(("head_object", Key))
        if Key not in self.objects:
            raise self._err("404", "HeadObject")
        data, ctype = self.objects[Key]
        return {"ContentLength": len(data), "ContentType": ctype}

    def get_object(self, Bucket, Key):
        self.calls.append(("get_object", Key))
        if self.fail_get:
            raise self._err("InternalError", "GetObject")
        if Key not in self.objects:
            raise self._err("NoSuchKey", "GetObject")
        return {"Body": io.BytesIO(self.objects[Key][0])}

    def put_object(self, Bucket, Key, Body, ContentType=None, **kw):
        self.calls.append(("put_object", Key))
        if self.fail_put:
            raise self._err("InternalError", "PutObject")
        self.objects[Key] = (bytes(Body), ContentType)

    def delete_object(self, Bucket, Key):
        self.calls.append(("delete_object", Key))
        self.objects.pop(Key, None)

    def copy_object(self, **kw):
        self.calls.append(("copy_object", kw.get("Key")))
        raise AssertionError("copy_object must never be used for listing media")

    def generate_presigned_post(self, **kw):
        return self._real.generate_presigned_post(**kw)

    def generate_presigned_url(self, *a, **kw):
        return self._real.generate_presigned_url(*a, **kw)

    def called(self, method):
        return [k for m, k in self.calls if m == method]


def install_stub_s3():
    stub = StubS3()
    attachments.S3_BUCKET_NAME = BUCKET
    attachments.S3_REGION = "us-east-1"
    attachments._s3_client = stub
    attachments._client = lambda: stub
    return stub


# -- image fixtures --------------------------------------------------------------------

def _rgb(w, h):
    im = Image.new("RGB", (w, h), (200, 30, 30))
    px = im.load()
    for x in range(min(w, 8)):          # a marker in the top-left corner
        for y in range(min(h, 8)):
            px[x, y] = (0, 0, 255)
    return im


def jpeg_bytes(w=64, h=32, exif=None, icc=None, quality=90):
    out = io.BytesIO()
    kw = {"format": "JPEG", "quality": quality}
    if exif is not None:
        kw["exif"] = exif
    if icc is not None:
        kw["icc_profile"] = icc
    _rgb(w, h).save(out, **kw)
    return out.getvalue()


def png_bytes(w=64, h=32, text=None, pad_to=0):
    from PIL.PngImagePlugin import PngInfo
    out = io.BytesIO()
    info = None
    if text:
        info = PngInfo()
        for k, v in text.items():
            info.add_text(k, v)
    _rgb(w, h).save(out, format="PNG", pnginfo=info)
    return out.getvalue()


def webp_bytes(w=64, h=32):
    out = io.BytesIO()
    _rgb(w, h).save(out, format="WEBP", quality=80)
    return out.getvalue()


def noisy_jpeg(target_bytes):
    """A JPEG of at least ``target_bytes`` (random noise does not compress)."""
    side = 64
    while True:
        im = Image.frombytes("RGB", (side, side), os.urandom(side * side * 3))
        out = io.BytesIO()
        im.save(out, format="JPEG", quality=95)
        if out.tell() >= target_bytes:
            return out.getvalue()
        side *= 2


def exif_with_gps(orientation=None):
    ex = Image.Exif()
    ex[0x010F] = "SecretCam"                       # Make
    gps = {1: "N", 2: (37.0, 46.0, 29.7), 3: "W", 4: (122.0, 25.0, 9.8)}
    ex[0x8825] = gps
    if orientation:
        ex[0x0112] = orientation
    return ex.tobytes()


def has_gps(data: bytes) -> bool:
    try:
        im = Image.open(io.BytesIO(data))
        ex = im.getexif()
        return bool(ex.get_ifd(0x8825)) or 0x8825 in ex
    except Exception:  # noqa: BLE001
        return False


def make_listing_user_group(extra_members=()):
    uid = make_user()
    gid = make_group(uid, list(extra_members))
    return uid, gid


# -- db / users / groups ------------------------------------------------------------

def q(sql, params=(), fetch=True):
    db = DBManager()
    try:
        db.cur.execute(sql, params)
        rows = db.cur.fetchall() if fetch and db.cur.description else None
        db.conn.commit()
        return rows
    finally:
        db.close()


def make_user(suspended=False, terms=CURRENT_TERMS_VERSION, paid=True):
    uid = str(uuid.uuid4())
    q("INSERT INTO users (_id, username, email, hash_pass, suspended_at, terms_version) VALUES (%s,%s,%s,'x',%s,%s)",
      (uid, f"lm_{uid[:8]}", f"lm_{uid[:8]}@example.com", "2020-01-01" if suspended else None, terms), fetch=False)
    USERS.append(uid)
    if paid:
        grant_paid(uid)
    return uid


def make_group(creator, members=None, title="Lm Test Group"):
    gid = str(uuid.uuid4())
    users = [creator] + [m for m in (members or []) if m != creator]
    q("INSERT INTO groups (_id, title, users, creator_id) VALUES (%s,%s,%s,%s)", (gid, title, users, creator), fetch=False)
    GROUPS.append(gid)
    return gid


def hdr(uid):
    sm = SessionManager()
    try:
        return {"cookie": f"session={sm.create_session(uid)}"}
    finally:
        sm.close()


def set_flag_sql(name, state, canary=None):
    q("UPDATE feature_flags SET state = %s, canary_user_ids = %s::uuid[] WHERE name = %s",
      (state, canary or [], name), fetch=False)
    flags.invalidate()


def snapshot_flags():
    return {r[0]: (r[1], r[2] or []) for r in q("SELECT name, state, canary_user_ids::text[] FROM feature_flags")}


def restore_flags(saved):
    for name, (state, canary) in saved.items():
        q("UPDATE feature_flags SET state = %s, canary_user_ids = %s::uuid[] WHERE name = %s",
          (state, canary, name), fetch=False)
    flags.invalidate()


def cleanup():
    for g in GROUPS:
        keys = [r[0] for r in (q("SELECT m.object_key FROM group_listing_media m JOIN group_listings gl ON gl._id = m.listing_id "
                                 "WHERE gl.group_id = %s", (g,)) or [])]
        for k in keys:
            q("DELETE FROM pending_s3_deletes WHERE key = %s", (k,), fetch=False)
        q("DELETE FROM invites WHERE target_id = %s", (g,), fetch=False)
        q("DELETE FROM messages WHERE group_id = %s", (g,), fetch=False)
        q("DELETE FROM groups WHERE _id = %s", (g,), fetch=False)
    for u in USERS:
        q("DELETE FROM content_reports WHERE reporter_id = %s OR reported_user_id = %s", (u, u), fetch=False)
        q("DELETE FROM users WHERE _id = %s", (u,), fetch=False)


def outbox_keys():
    return {r[0] for r in (q("SELECT key FROM pending_s3_deletes") or [])}


def purge_outbox(prefix="listings/"):
    q("DELETE FROM pending_s3_deletes WHERE key LIKE %s", (prefix + "%",), fetch=False)


class LogCatcher(logging.Handler):
    def __init__(self):
        super().__init__(level=logging.DEBUG)
        self.records = []

    def emit(self, record):
        self.records.append((record.levelname, record.getMessage()))


class catch_logs:
    def __enter__(self):
        self.h = LogCatcher()
        self.root = logging.getLogger()
        self.old = self.root.level
        self.root.setLevel(logging.DEBUG)
        self.root.addHandler(self.h)
        return self.h

    def __exit__(self, *a):
        self.root.removeHandler(self.h)
        self.root.setLevel(self.old)


def raises_listing_error(fn, *a, **k):
    from backend.interactions.listing_content import ListingError
    try:
        fn(*a, **k)
    except ListingError as e:
        return e
    return None


# -- HTTP helpers (imported lazily: main pulls in the whole app) ------------------------------

def app_client():
    from fastapi.testclient import TestClient
    import main as main_module
    from backend.registrations import load_all
    load_all()
    return TestClient(main_module.app)


def reset_limits():
    from backend.rate_limiting import limiter
    limiter.reset()


def base(uid, gid):
    return f"/explorer/{uid}/groups/{gid}/listing"


def create_listing(cli, uid, gid, body=None):
    reset_limits()
    r = cli.put(base(uid, gid), json=body or {}, headers=hdr(uid))
    assert r.status_code == 200, (r.status_code, r.text)
    return q("SELECT public_id FROM group_listings WHERE group_id = %s", (gid,))[0][0]


def stage_upload(stub, public_id, data, mime, ext=None):
    """Put ``data`` where a client's presigned POST would have, return its key."""
    from backend.interactions import listings_media as lm
    key = lm.build_key(public_id, mime)
    stub.put(key, data, mime)
    return key


def confirm(cli, uid, gid, kind, key, alt=None, hh=None):
    reset_limits()
    body = {"kind": kind, "object_key": key}
    if alt is not None:
        body["alt_text"] = alt
    return cli.post(base(uid, gid) + "/media/confirm", json=body, headers=hh or hdr(uid))


def listing_status(gid):
    r = q("SELECT status FROM group_listings WHERE group_id = %s", (gid,))
    return r[0][0] if r else None


def publish(cli, uid, gid, admin):
    """submit + admin approve -> published."""
    from backend.interactions import listings
    reset_limits()
    r = cli.post(base(uid, gid) + "/submit", json={"consent": True, "adult_attested": True}, headers=hdr(uid))
    assert r.status_code == 200, (r.status_code, r.text)
    pid = q("SELECT public_id FROM group_listings WHERE group_id = %s", (gid,))[0][0]
    approve(pid, admin)
    assert listing_status(gid) == "published", listing_status(gid)
    return pid


def approve(public_id, admin):
    from backend.interactions import listings
    db = DBManager()
    try:
        out = listings.admin_approve(db.cur, public_id, admin)
        db.conn.commit()
        return out
    finally:
        db.close()
